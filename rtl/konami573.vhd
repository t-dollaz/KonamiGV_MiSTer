library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Konami System 573 EXP1 device  (Increment A: full register-level behaviour)
-- Ported from the working DuckStation fork's konami.cpp (duckstation-sb-2(old)).
-- Implements the fake 53C94 SCSI register FSM, the 128 B EEPROM (in M10K via dpram),
-- flash address window, P1/P2 inputs, trackball registers, watchdog, and IRQ10.
-- DEFERRED to later increments (stubbed at clean seams):
--   * disc sector delivery  -> DMA channel 5 (Increment B); FSM here only latches LBA/status
--   * flash DATA             -> 8 MB in DDR3 (Increment C); addressing logic is present
--   * EEPROM load/save + real button/trackball inputs -> HPS wiring (Increment D)
-- The 8-bit EXP1 bus is byte-stepped by memorymux; bus_addr(1:0) is the byte lane
-- (memorymux drives those low bits from ext_byteStep).

entity konami573 is
   generic (
      DBG_PC_CNT_BITS : integer := 25   -- DEBUG-probe counter width: ~0.6s/phase on hw; TB overrides small
   );
   port (
      clk1x         : in  std_logic;
      ce            : in  std_logic;
      reset         : in  std_logic;

      -- EXP1 bus (8-bit, byte-stepped)
      bus_addr      : in  unsigned(22 downto 0);
      bus_dataWrite : in  std_logic_vector(7 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(7 downto 0);

      -- IRQ10 to the interrupt controller (one-cycle pulse -> edge latched)
      irq10_set     : out std_logic := '0';

      -- DMA channel 5 provider (internal to psx_top, wired to idma)
      DMA_EXP_read     : out std_logic_vector(31 downto 0);  -- 32-bit word to DMA fifo
      DMA_EXP_readEna  : in  std_logic;                      -- DMA is reading this cycle
      exp_dmaRequest   : out std_logic := '0';               -- channel requestable (= dmaArmed)
      exp_dmaDataValid : out std_logic := '0';               -- buffer ready (gates readStall)
      dma5_done        : in  std_logic;                      -- ch5 transfer complete strobe

      -- disc sector fetch from HPS (sd_* slot 4; 1024-byte blocks, 2 blocks/sector)
      disc_req      : out std_logic := '0';
      disc_lba      : out std_logic_vector(31 downto 0) := (others => '0');
      disc_ack      : in  std_logic;
      disc_wr       : in  std_logic;
      disc_addr     : in  std_logic_vector(8 downto 0);
      disc_data     : in  std_logic_vector(15 downto 0);
      disc_mounted  : in  std_logic;

      -- flash data window (Increment C): 8 MB in DDR3, served by a clk2x FSM in psx_top.
      -- konami573 presents the 16-bit word index and a fetch strobe; psx_top returns the word.
      flash_word_addr  : out std_logic_vector(23 downto 0) := (others => '0');
      flash_fetch      : out std_logic := '0';      -- pulse when FlashAddress changes -> prefetch
      flash_data       : in  std_logic_vector(15 downto 0); -- interleaved 16-bit word at FlashAddress
      flash_data_ready : in  std_logic;             -- word valid (unused: prefetch hides latency)

      -- EEPROM persistence (Increment D-eeprom): memcard-style HPS save mount on sd_* slot 0.
      -- 128 B = 64 16-bit words in the first part of one 1024-byte block. Load on mount, save on dirty.
      eeprom_load      : in  std_logic;             -- pulse: (re)load from the mounted file
      eeprom_save      : in  std_logic;             -- pulse: write back if dirty (shared OSD/autosave trigger)
      eeprom_mounted   : in  std_logic;
      eeprom_rd        : out std_logic := '0';
      eeprom_wr        : out std_logic := '0';
      eeprom_ack       : in  std_logic;
      eeprom_write     : in  std_logic;             -- sd_buff_wr (HPS->core during a read block)
      eeprom_addr      : in  std_logic_vector(8 downto 0); -- sd_buff_addr (word index in the block)
      eeprom_dataIn    : in  std_logic_vector(15 downto 0); -- sd_buff_dout
      eeprom_dataOut   : out std_logic_vector(15 downto 0); -- sd_buff_din slot 0

      -- inputs (Increment D)
      buttons       : in  unsigned(31 downto 0);   -- raw pad state, active-LOW (konami.cpp KonamiButtonsSet arg)
      mouse_event   : in  std_logic;               -- relative mouse sample strobe (trackball)
      mouse_x       : in  signed(8 downto 0);      -- relative X delta
      mouse_y       : in  signed(8 downto 0);      -- relative Y delta

      cpu_pc        : in  unsigned(31 downto 0) := (others => '0')  -- DEBUG: CPU program counter (cpu_export.pc)
   );
end entity;

architecture arch of konami573 is

   type t_bytes16 is array(0 to 15) of std_logic_vector(7 downto 0);
   signal ScsiRegs     : t_bytes16 := (others => (others => '0'));
   signal ScsiFifo     : t_bytes16 := (others => (others => '0'));
   signal ScsiFifoPtr  : integer range 0 to 15 := 0;
   type t_bytes12 is array(0 to 11) of std_logic_vector(7 downto 0);
   signal ScsiCommand  : t_bytes12 := (others => (others => '0'));
   signal ScsiIsRead   : std_logic := '0';
   signal ScsiSectorLba: unsigned(31 downto 0) := (others => '0');

   constant REG_FIFO      : integer := 2;
   constant REG_COMMAND   : integer := 3;
   constant REG_STATUS    : integer := 4;
   constant REG_IRQSTATE  : integer := 5;
   constant REG_INTSTATE  : integer := 6;
   constant REG_FIFOSTATE : integer := 7;

   signal FlashAddress : unsigned(23 downto 0) := (others => '0');

   -- CurrentButtons = buttons XOR 0xFFFFFFFF (konami.cpp KonamiButtonsSet)
   signal CurrentButtons : unsigned(31 downto 0);

   -- EEPROM (128 bytes) in M10K block RAM. Port A = EXP1 (byte); port B = HPS save mount (16-bit).
   signal ee_addr : std_logic_vector(6 downto 0);
   signal ee_wren : std_logic;
   signal ee_q    : std_logic_vector(7 downto 0);
   signal eep_addr_b : std_logic_vector(5 downto 0);
   signal eep_wren_b : std_logic;

   -- EEPROM save-mount FSM (memcard-modeled, no DDR3 leg — the EEPROM lives in the dpram here)
   type tEepState is (EE_IDLE, EE_LOAD_WSTART, EE_LOAD_WDONE, EE_SAVE_WSTART, EE_SAVE_WDONE);
   signal eepState     : tEepState := EE_IDLE;
   signal eep_loading  : std_logic := '0';
   signal eeprom_dirty : std_logic := '0';
   signal loadLatched  : std_logic := '0';
   signal saveLatched  : std_logic := '0';

   signal region  : integer range 0 to 127;
   signal scsiReg : integer range 0 to 15;
   signal bsel    : integer range 0 to 3;     -- byte lane within the access

   -- P1 active-low value (konami.cpp KonamiP1Read)
   signal p1val   : std_logic_vector(31 downto 0);

   -- Trackball: relative mouse deltas accumulated into signed 12-bit X/Y, reset when the
   -- game reads them (konami.cpp models a relative trackball). Range clamped to +-2048.
   signal TrackballX : signed(11 downto 0) := (others => '0');
   signal TrackballY : signed(11 downto 0) := (others => '0');

   -- ===== Increment B: DMA channel-5 disc-sector provider =====
   -- Disc-fetch FSM, modeled on rtl/memcard.vhd LOAD path.
   type tDiscState is (D_IDLE, D_REQ, D_WAITSTART, D_WAITDONE);
   signal discState   : tDiscState := D_IDLE;
   signal blkIdx      : std_logic := '0';            -- which 1024B half of the 2048B sector
   signal fetchStart  : std_logic := '0';            -- latched request to fetch a sector
   signal bufferValid : std_logic := '0';            -- current sector is in the buffer
   signal dmaArmed    : std_logic := '0';            -- a DMA-bearing command is pending
   signal dmaWordIdx  : unsigned(8 downto 0) := (others => '0'); -- 32-bit word index 0..511

   -- sector buffer (dpram_dif): port A 512x32 = DMA drain, port B 1024x16 = HPS fill
   signal buf_addr_a  : std_logic_vector(8 downto 0);
   signal buf_addr_b  : std_logic_vector(9 downto 0);
   signal buf_q_a     : std_logic_vector(31 downto 0);
   signal buf_wren_b  : std_logic;

   signal dmaDataValid_s : std_logic;
   signal dmaConsume     : std_logic;

   -- ===== DEBUG PROBE: CPU program-counter readout via the disc-read channel =====
   -- A slow counter cycles 3 phases; each fires a background disc read at an LBA encoding part of
   -- cpu_pc (stable while the CPU is hung in a loop). Decode the S4 fd offset (LBA = pos/2048):
   --   LBA < 0x800        -> PC(12:2)  = LBA
   --   0x800 <= LBA<0x1000-> PC(23:13) = LBA - 0x800
   --   0x1000<= LBA<0x1100-> PC(31:24) = LBA - 0x1000
   -- Combine -> full PC. All LBAs < ISO's ~24395 sectors. Gated to D_IDLE so it never disturbs a
   -- real disc read (on a working boot it simply defers).
   signal dbg_pc_cnt   : unsigned(DBG_PC_CNT_BITS-1 downto 0) := (others => '0');
   signal dbg_pc_phase : unsigned(1 downto 0) := (others => '0');
   signal dbg_pc_latch : unsigned(31 downto 0) := (others => '0');  -- PC snapshot (frozen at phase 0)

begin

   region  <= to_integer(bus_addr(22 downto 16));
   scsiReg <= to_integer(bus_addr(4 downto 1));
   bsel    <= to_integer(bus_addr(1 downto 0));
   CurrentButtons <= buttons xor x"FFFFFFFF";

   -- P1 inputs assembled combinationally (active-low), per konami.cpp bit masks
   p1val(31 downto 10) <= (others => '1');
   p1val(9)  <= '0' when (CurrentButtons(3) = '1' or CurrentButtons(8) = '1' or
                          CurrentButtons(10) = '1' or CurrentButtons(11) = '1') else '1'; -- START (0x0D08)
   p1val(8)  <= '1';
   p1val(7 downto 5) <= "111";
   p1val(4)  <= '0' when (CurrentButtons(13) = '1' or CurrentButtons(14) = '1') else '1'; -- BUTTON1 (0x6000)
   p1val(3)  <= '0' when (CurrentButtons(6) = '1') else '1';  -- DOWN  (0x0040)
   p1val(2)  <= '0' when (CurrentButtons(4) = '1') else '1';  -- UP    (0x0010)
   p1val(1)  <= '0' when (CurrentButtons(5) = '1') else '1';  -- RIGHT (0x0020)
   p1val(0)  <= '0' when (CurrentButtons(7) = '1') else '1';  -- LEFT  (0x0080)

   -- EEPROM block RAM (M10K). Port A = EXP1 bus (byte); Port B = HPS save mount (16-bit word).
   ee_addr <= std_logic_vector(bus_addr(6 downto 0));
   ee_wren <= '1' when (ce = '1' and bus_write = '1' and region = 16#18#) else '0';
   -- Port B tracks the sd_buff word address; only the first 64 words (128 B) are the EEPROM.
   eep_addr_b <= eeprom_addr(5 downto 0);
   eep_wren_b <= (eeprom_write and eeprom_ack and eep_loading) when eeprom_addr(8 downto 6) = "000" else '0';
   ieeprom : entity work.dpram_dif
      generic map (addr_width_a => 7, data_width_a => 8, addr_width_b => 6, data_width_b => 16)
      port map (
         clock_a => clk1x, clken_a => ce, address_a => ee_addr, data_a => bus_dataWrite, wren_a => ee_wren, q_a => ee_q,
         clock_b => clk1x, address_b => eep_addr_b, data_b => eeprom_dataIn, wren_b => eep_wren_b, q_b => eeprom_dataOut
      );

   -- Sector buffer. Port B is filled AUTOMATICALLY from the HPS sd_buff stream during the
   -- disc_ack window (exactly like memcard.vhd), addressed by blkIdx & disc_addr.
   buf_wren_b <= disc_wr and disc_ack;
   buf_addr_b <= blkIdx & disc_addr;
   isectorBuffer : entity work.dpram_dif
      generic map (addr_width_a => 9, data_width_a => 32, addr_width_b => 10, data_width_b => 16)
      port map (
         clock_a => clk1x, address_a => buf_addr_a, q_a => buf_q_a,           -- port A: DMA drain (read-only)
         clock_b => clk1x, address_b => buf_addr_b, data_b => disc_data, wren_b => buf_wren_b, q_b => open
      );

   -- READ(10) waits for the buffer; constant-payload commands are always ready.
   dmaDataValid_s   <= bufferValid when ScsiIsRead = '1' else '1';
   exp_dmaDataValid <= dmaDataValid_s;
   exp_dmaRequest   <= dmaArmed;

   -- A word is consumed only when the DMA engine reads AND data is valid. ce-gated to match
   -- dma.vhd's own consume condition (its WORKING transfer is inside its ce block).
   dmaConsume <= ce and DMA_EXP_readEna and dmaDataValid_s;

   -- Present the next read address one cycle ahead to hide the dpram port-A read latency:
   -- q_a(T) = buffer[addr_a(T-1)], and addr_a = dmaWordIdx (+1 on consume) makes q_a track the
   -- word the DMA latches this cycle. 9-bit wrap turns 511->0 at the sector boundary.
   buf_addr_a <= std_logic_vector(dmaWordIdx + 1) when dmaConsume = '1' else std_logic_vector(dmaWordIdx);

   -- DMA data: sector bytes for READ(10); constant payloads for INQUIRY/SENSE/TOC (konami.cpp).
   DMA_EXP_read <= buf_q_a     when ScsiCommand(0) = x"28" else
                   x"01010008" when (ScsiCommand(0) = x"43" and dmaWordIdx = 0) else
                   x"00010400" when (ScsiCommand(0) = x"43" and dmaWordIdx = 1) else
                   (others => '0');

   -- Flash word index presented continuously to the psx_top DDR3 fetch FSM.
   flash_word_addr <= std_logic_vector(FlashAddress);

   -- EEPROM save-mount FSM: load the 128 B dump on mount, write it back when dirty. The sd_*
   -- rd/wr handshake mirrors memcard.vhd (assert until ack; the buffer streams during the ack
   -- window via dpram port B). Runs free of the EXP1 ce gate (HPS handshake is independent of it).
   eeprom_save_proc : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if reset = '1' then
            eepState     <= EE_IDLE;
            eeprom_rd    <= '0';
            eeprom_wr    <= '0';
            eep_loading  <= '0';
            eeprom_dirty <= '0';
            loadLatched  <= '0';
            saveLatched  <= '0';
         else
            if eeprom_load = '1' then loadLatched <= '1'; end if;
            if eeprom_save = '1' then saveLatched <= '1'; end if;

            case eepState is
               when EE_IDLE =>
                  if (loadLatched = '1' and eeprom_mounted = '1') then
                     eeprom_rd   <= '1';
                     eep_loading <= '1';
                     loadLatched <= '0';
                     eepState    <= EE_LOAD_WSTART;
                  elsif (saveLatched = '1') then
                     saveLatched <= '0';
                     if (eeprom_dirty = '1' and eeprom_mounted = '1') then
                        eeprom_wr <= '1';
                        eepState  <= EE_SAVE_WSTART;
                     end if;
                  end if;

               when EE_LOAD_WSTART =>            -- read block: wait ack rising
                  if (eeprom_ack = '1') then
                     eeprom_rd <= '0';
                     eepState  <= EE_LOAD_WDONE;
                  end if;

               when EE_LOAD_WDONE =>             -- buffer filled during ack; wait ack falling
                  if (eeprom_ack = '0') then
                     eep_loading  <= '0';
                     eeprom_dirty <= '0';        -- freshly loaded == clean
                     eepState     <= EE_IDLE;
                  end if;

               when EE_SAVE_WSTART =>            -- write block: wait ack rising
                  if (eeprom_ack = '1') then
                     eeprom_wr <= '0';
                     eepState  <= EE_SAVE_WDONE;
                  end if;

               when EE_SAVE_WDONE =>             -- wait ack falling
                  if (eeprom_ack = '0') then
                     eeprom_dirty <= '0';        -- saved == clean
                     eepState     <= EE_IDLE;
                  end if;
            end case;

            -- A game EEPROM write always wins (placed after the case) so a write coinciding with
            -- a save/load completion never silently loses the dirty flag.
            if ee_wren = '1' then eeprom_dirty <= '1'; end if;
         end if;
      end if;
   end process;

   process (clk1x)
      variable v_status   : std_logic_vector(7 downto 0);
      variable v_intstate : std_logic_vector(7 downto 0);
      variable v_irqstate : std_logic_vector(7 downto 0);
      variable v_irq      : std_logic;
      variable cmd        : integer range 0 to 127;
      variable v_tbreset  : std_logic;
      variable v_tx       : signed(12 downto 0);
      variable v_ty       : signed(12 downto 0);
   begin
      if rising_edge(clk1x) then

         irq10_set   <= '0';  -- default: assert is a one-cycle pulse
         flash_fetch <= '0';  -- default: pulse one cycle when FlashAddress changes
         v_tbreset   := '0';

         if reset = '1' then
            ScsiFifoPtr  <= 0;
            ScsiIsRead   <= '0';
            FlashAddress <= (others => '0');
            ScsiRegs     <= (others => (others => '0'));
            bus_dataRead <= (others => '1');
            discState    <= D_IDLE;
            blkIdx       <= '0';
            fetchStart   <= '0';
            bufferValid  <= '0';
            dmaArmed     <= '0';
            dmaWordIdx   <= (others => '0');
            disc_req     <= '0';
            dbg_pc_cnt   <= (others => '0');
            dbg_pc_phase <= (others => '0');
            TrackballX   <= (others => '0');
            TrackballY   <= (others => '0');

         elsif ce = '1' then

            ------------------------------------------------------------------
            -- DEBUG PROBE: emit the CPU program counter over the disc-read channel.
            -- Free-running counter; on wrap, fire one disc read whose LBA encodes a
            -- slice of cpu_pc (3 phases). Gated to D_IDLE + no pending real read, so
            -- it never disturbs an actual disc transfer.
            ------------------------------------------------------------------
            dbg_pc_cnt <= dbg_pc_cnt + 1;
            if (dbg_pc_cnt = 0 and discState = D_IDLE and dmaArmed = '0' and fetchStart = '0') then
               -- SNAPSHOT: freeze the whole PC at phase 0, then emit all 3 slices from the latch,
               -- so the 3 disc reads describe ONE PC (the v1 bug sampled 3 different-time PCs).
               case dbg_pc_phase is
                  when "00"   => dbg_pc_latch <= cpu_pc;
                                 ScsiSectorLba <= resize(cpu_pc(12 downto 2), 32);                              -- =snapshot(12:2)
                  when "01"   => ScsiSectorLba <= to_unsigned(16#0800#, 32) + resize(dbg_pc_latch(23 downto 13), 32);
                  when others => ScsiSectorLba <= to_unsigned(16#1000#, 32) + resize(dbg_pc_latch(31 downto 24), 32);
               end case;
               fetchStart  <= '1';
               bufferValid <= '0';
               if (dbg_pc_phase = 2) then dbg_pc_phase <= "00"; else dbg_pc_phase <= dbg_pc_phase + 1; end if;
            end if;

            ------------------------------------------------------------------
            -- READ
            ------------------------------------------------------------------
            bus_dataRead <= (others => '1');
            if bus_read = '1' then
               case region is
                  when 16#00# =>                                   -- SCSI 0x000000-0x00001F
                     bus_dataRead <= ScsiRegs(scsiReg);
                     if scsiReg = REG_FIFO then
                        bus_dataRead <= (others => '0');
                     elsif scsiReg = REG_IRQSTATE then
                        ScsiRegs(REG_STATUS) <= ScsiRegs(REG_STATUS) and x"7F";  -- clear bit 0x80
                     end if;

                  when 16#10# =>                                   -- P1 0x100000 / P2 0x100004
                     if bus_addr(2) = '1' then
                        bus_dataRead <= (others => '1');            -- P2 = 0xFF
                     else
                        case bsel is
                           when 0      => bus_dataRead <= p1val(7  downto  0);
                           when 1      => bus_dataRead <= p1val(15 downto  8);
                           when 2      => bus_dataRead <= p1val(23 downto 16);
                           when others => bus_dataRead <= p1val(31 downto 24);
                        end case;
                     end if;

                  when 16#18# =>                                   -- EEPROM 0x180080-0x1800FF
                     bus_dataRead <= ee_q;

                  when 16#68# =>                                   -- flash 0x6800{80..8F} / trackball 0x6800{C0..C9}
                     if bus_addr(7 downto 4) = "1100" then         -- 0xC0..0xCF trackball window
                        if bus_addr(3) = '0' then                  -- 0xC0..0xC7 data (axis in HIGH byte, low byte 0)
                           if bus_addr(0) = '0' then
                              bus_dataRead <= (others => '0');                                          -- low byte
                           else
                              case to_integer(bus_addr(2 downto 1)) is
                                 when 0      => bus_dataRead <= std_logic_vector(TrackballX(7 downto 0));            -- C0 hi
                                 when 1      => bus_dataRead <= "0000" & std_logic_vector(TrackballX(11 downto 8));  -- C2 hi
                                 when 2      => bus_dataRead <= std_logic_vector(TrackballY(7 downto 0));            -- C4 hi
                                 when others => bus_dataRead <= "0000" & std_logic_vector(TrackballY(11 downto 8));  -- C6 hi
                              end case;
                           end if;
                        else                                       -- 0xC8 (konami.cpp default case) -> zero counters
                           v_tbreset := '1';
                        end if;
                     elsif bus_addr(7 downto 4) = "1000" then      -- 0x80..0x8F flash data port
                        if bus_addr(3 downto 1) = "000" then        -- offset 0: 16-bit interleaved word
                           if bus_addr(0) = '0' then
                              bus_dataRead <= flash_data(7 downto 0);    -- low byte  (Flash[Chip])
                           else
                              bus_dataRead <= flash_data(15 downto 8);   -- high byte (Flash[Chip+1])
                              FlashAddress <= FlashAddress + 1;          -- FA++ after the high byte
                              flash_fetch  <= '1';                       -- prefetch next word
                           end if;
                        elsif bus_addr(3 downto 1) = "100" then     -- offset 8: FA |= 1
                           bus_dataRead <= (others => '0');
                           FlashAddress <= FlashAddress or to_unsigned(1, FlashAddress'length);
                           flash_fetch  <= '1';
                        else
                           bus_dataRead <= (others => '0');
                        end if;
                     else
                        bus_dataRead <= (others => '0');             -- 0x780000 watchdog etc
                     end if;

                  when others => null;                             -- 0x780000 watchdog etc -> 0xFF
               end case;
            end if;

            ------------------------------------------------------------------
            -- WRITE
            ------------------------------------------------------------------
            if bus_write = '1' then
               case region is

                  when 16#00# =>                                   -- SCSI register write
                     v_status   := ScsiRegs(REG_STATUS);
                     v_intstate := ScsiRegs(REG_INTSTATE);
                     v_irqstate := ScsiRegs(REG_IRQSTATE);
                     v_irq      := '0';

                     case scsiReg is
                        when 0 | 1 | 14 =>                          -- XFERCNT LOW/MID/HI
                           v_status := v_status and x"EF";         -- clear 0x10
                        when REG_FIFO =>
                           ScsiFifo(ScsiFifoPtr) <= bus_dataWrite;
                           if ScsiFifoPtr < 15 then ScsiFifoPtr <= ScsiFifoPtr + 1; end if;
                        when REG_COMMAND =>
                           ScsiFifoPtr <= 0;
                           cmd := to_integer(unsigned(bus_dataWrite(6 downto 0)));
                           case cmd is
                              when 16#00# =>
                                 v_irqstate := x"08";
                              when 16#02# =>
                                 v_irqstate := x"08"; v_status := v_status or x"80"; v_irq := '1';
                              when 16#03# =>
                                 v_intstate := x"04"; v_irq := '1';
                              when 16#42# =>
                                 if ScsiFifo(1) = x"00" or ScsiFifo(1) = x"48" or ScsiFifo(1) = x"4B" then
                                    v_intstate := x"06";
                                 else
                                    v_intstate := x"04";
                                 end if;
                                 for i in 0 to 11 loop ScsiCommand(i) <= ScsiFifo(1 + i); end loop;
                                 ScsiIsRead <= '0';
                                 case ScsiFifo(1) is               -- command opcode = ScsiFifo[1]
                                    when x"03" | x"12" | x"1A" | x"43" =>  -- INQUIRY/SENSE/TOC: const DMA payload
                                       v_status := (v_status and x"F8") or x"01";
                                       dmaArmed   <= '1';
                                       dmaWordIdx <= (others => '0');
                                    when x"15" =>
                                       v_status := (v_status and x"F8");
                                    when x"28" =>                  -- READ(10): latch LBA, arm sector fetch
                                       ScsiSectorLba <= unsigned(ScsiFifo(3)) & unsigned(ScsiFifo(4)) &
                                                        unsigned(ScsiFifo(5)) & unsigned(ScsiFifo(6));
                                       ScsiIsRead <= '1';
                                       v_status := (v_status and x"F8") or x"01";
                                       dmaArmed    <= '1';
                                       fetchStart  <= '1';
                                       bufferValid <= '0';
                                       dmaWordIdx  <= (others => '0');
                                    when others => null;
                                 end case;
                                 v_irq := '1';
                              when 16#44# => null;
                              when 16#10# =>
                                 if bus_dataWrite(7) = '1' then
                                    v_status := (v_status and x"F8") or x"03"; v_intstate := x"00"; v_irq := '1';
                                 else                              -- fallthrough 0x10 -> 0x11 -> 0x12
                                    v_irq := '1'; v_status := v_status and x"78"; v_intstate := x"00";
                                    v_status := v_status or x"80"; v_intstate := x"06";
                                 end if;
                              when 16#11# =>                       -- fallthrough 0x11 -> 0x12
                                 v_irq := '1'; v_status := v_status and x"78"; v_intstate := x"00";
                                 v_status := v_status or x"80"; v_intstate := x"06";
                              when 16#12# =>
                                 v_status := v_status or x"80"; v_intstate := x"06";
                              when others => null;
                           end case;
                        when others => null;
                     end case;

                     -- konami.cpp: write value to the reg UNLESS it is STATUS/INTSTATE/IRQSTATE/FIFOSTATE
                     if scsiReg /= REG_STATUS and scsiReg /= REG_INTSTATE and
                        scsiReg /= REG_IRQSTATE and scsiReg /= REG_FIFOSTATE then
                        ScsiRegs(scsiReg) <= bus_dataWrite;
                     end if;
                     ScsiRegs(REG_STATUS)   <= v_status;
                     ScsiRegs(REG_INTSTATE) <= v_intstate;
                     ScsiRegs(REG_IRQSTATE) <= v_irqstate;
                     if v_irq = '1' then irq10_set <= '1'; end if;

                  when 16#68# =>                                   -- flash address writes (0x82/0x84/0x86, 8-bit)
                     if bus_addr(7 downto 4) = "1000" then         -- flash window only (not trackball 0xC0+)
                        case to_integer(bus_addr(3 downto 0)) is
                           when 2 => FlashAddress <= shift_left(resize(unsigned(bus_dataWrite), 24), 1);
                                     flash_fetch  <= '1';
                           when 4 => FlashAddress <= (FlashAddress and to_unsigned(16#FF00FF#, 24)) or
                                                     shift_left(resize(unsigned(bus_dataWrite), 24), 8);
                                     flash_fetch  <= '1';
                           when 6 => FlashAddress <= (FlashAddress and to_unsigned(16#00FFFF#, 24)) or
                                                     shift_left(resize(unsigned(bus_dataWrite), 24), 15);
                                     flash_fetch  <= '1';
                           when others => null;
                        end case;
                     end if;

                  when others => null;
               end case;
            end if;

            ------------------------------------------------------------------
            -- Disc-fetch FSM (mirrors memcard.vhd LOAD: REQ -> WAITACKSTART ->
            -- WAITACKDONE). The buffer fills via dpram port B automatically while
            -- disc_ack is high; here we only sequence the two blocks per sector.
            ------------------------------------------------------------------
            if disc_ack = '1' then
               disc_req <= '0';                                   -- rd cleared on ack (memcard pattern)
            end if;

            case discState is
               when D_IDLE =>
                  if fetchStart = '1' and disc_mounted = '1' then
                     blkIdx     <= '0';
                     fetchStart <= '0';
                     discState  <= D_REQ;
                  end if;

               when D_REQ =>
                  disc_lba  <= std_logic_vector(ScsiSectorLba(30 downto 0)) & blkIdx;  -- lba*2 + blkIdx
                  disc_req  <= '1';
                  discState <= D_WAITSTART;

               when D_WAITSTART =>
                  if disc_ack = '1' then
                     discState <= D_WAITDONE;
                  end if;

               when D_WAITDONE =>
                  if disc_ack = '0' then                          -- block now resident in buffer
                     if blkIdx = '0' then
                        blkIdx    <= '1';
                        discState <= D_REQ;
                     else
                        bufferValid <= '1';
                        discState   <= D_IDLE;
                     end if;
                  end if;
            end case;

            ------------------------------------------------------------------
            -- DMA drain bookkeeping. On each consumed 32-bit word advance the
            -- read index; at the sector boundary (READ(10)) step the LBA and
            -- refetch the next sector (DMA stalls meanwhile via dmaDataValid_s).
            ------------------------------------------------------------------
            if dmaConsume = '1' then
               if ScsiIsRead = '1' then
                  if dmaWordIdx = 511 then
                     dmaWordIdx    <= (others => '0');
                     ScsiSectorLba <= ScsiSectorLba + 1;
                     bufferValid   <= '0';
                     fetchStart    <= '1';
                  else
                     dmaWordIdx <= dmaWordIdx + 1;
                  end if;
               elsif dmaWordIdx /= 511 then                       -- const payload word counter (saturates)
                  dmaWordIdx <= dmaWordIdx + 1;
               end if;
            end if;

            ------------------------------------------------------------------
            -- Completion. konami.cpp KonamiDmaControlWrite only clears
            -- ScsiRegs[4] & ~0x7 on DMA completion -- it does NOT raise IRQ10
            -- (IRQ10 is asserted at SCSI-command time, handled above).
            ------------------------------------------------------------------
            if dma5_done = '1' then
               ScsiRegs(REG_STATUS) <= ScsiRegs(REG_STATUS) and x"F8";
               ScsiIsRead  <= '0';
               dmaArmed    <= '0';
               bufferValid <= '0';
               dmaWordIdx  <= (others => '0');
               fetchStart  <= '0';   -- drop the speculative next-sector prefetch (if not yet started)
               -- NOTE: an in-flight disc fetch is left to finish so the HPS sd handshake stays in sync;
               -- its result is harmless (the next READ command re-arms fetchStart/bufferValid).
            end if;

            ------------------------------------------------------------------
            -- Trackball: relative mouse deltas accumulated, clamped to +-2048.
            -- A read of Y (C6) zeroes the pair (reset wins over a same-cycle delta).
            ------------------------------------------------------------------
            if v_tbreset = '1' then
               TrackballX <= (others => '0');
               TrackballY <= (others => '0');
            elsif mouse_event = '1' then
               v_tx := resize(TrackballX, 13) + resize(mouse_x, 13);
               v_ty := resize(TrackballY, 13) + resize(mouse_y, 13);
               if    v_tx >  2047 then TrackballX <= to_signed( 2047, 12);
               elsif v_tx < -2048 then TrackballX <= to_signed(-2048, 12);
               else                    TrackballX <= resize(v_tx, 12); end if;
               if    v_ty >  2047 then TrackballY <= to_signed( 2047, 12);
               elsif v_ty < -2048 then TrackballY <= to_signed(-2048, 12);
               else                    TrackballY <= resize(v_ty, 12); end if;
            end if;

         end if;
      end if;
   end process;

end architecture;
