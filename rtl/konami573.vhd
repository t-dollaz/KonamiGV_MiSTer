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
      bus_bstep     : in  std_logic_vector(1 downto 0) := "00";  -- byte-of-CPU-access (konami.cpp lane semantics; from memorymux ext_byteStep)
      bus_a10       : in  std_logic_vector(1 downto 0) := "00";  -- CPU access address bits 1:0, stable from access start
      irq10_rise_cnt : in unsigned(7 downto 0) := (others => '0');  -- IRQ10 latched into I_STAT (from psx_top counter)
      irq10_fall_cnt : in unsigned(7 downto 0) := (others => '0');  -- IRQ10 acked by CPU
      tball_speed   : in  std_logic_vector(1 downto 0) := "00";     -- OSD trackball sensitivity: delta >> speed (1x,1/2,1/4,1/8)
      tball_invert  : in  std_logic_vector(1 downto 0) := "00";     -- OSD trackball invert: bit0=X, bit1=Y
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
      flash_rdaddr     : in  std_logic_vector(23 downto 0) := (others => '1'); -- FA that flash_data is valid for (fix A)
      bus_exp1_wait    : out std_logic := '0';      -- fix A: stall the EXP1 read until flash_data is valid
      -- 29F016A write path (docs/FLASH_WRITE_DESIGN.md): program/erase ops executed by the
      -- psx_top memFlash FSM against DDR3. Level-based 4-phase req/done handshake (CDC-safe,
      -- per the flash_dl_done lesson). Authority: MAME konamigv.cpp:697-706 (flash_w case 0
      -- writes through to 4x FUJITSU_29F016A) + machine/intelfsh.cpp AMD command FSM.
      flash_op_req     : out std_logic := '0';
      flash_op_fill    : out std_logic := '0';      -- '1' = erase fill (0xFF), '0' = program RMW (AND)
      flash_op_addr    : out std_logic_vector(23 downto 0) := (others => '0'); -- word addr (fill: aligned base)
      flash_op_len     : out unsigned(21 downto 0) := (others => '0');         -- fill length in words
      flash_op_data    : out std_logic_vector(7 downto 0) := (others => '0');  -- program byte
      flash_op_lane    : out std_logic := '0';      -- '0' = lo chip byte, '1' = hi chip byte
      flash_op_done    : in  std_logic := '0';

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
   signal fl_wr_lo     : unsigned(7 downto 0) := (others => '0');  -- low byte latch for 16-bit flash-address writes

   -- ===== 29F016A command FSMs (docs/FLASH_WRITE_DESIGN.md) =====
   -- One FSM per byte lane = one per chip of the selected pair (konamigv.cpp:697-706: a
   -- 16-bit data-port write is one write() per chip). States/transitions are the AMD subset
   -- of MAME intelfsh.cpp write_full for MFG_FUJITSU 0x04 / device 0xAD (8-bit, 2MB, 64KB
   -- sectors). Command addresses use the chip word address = FlashAddress; unlock matches
   -- on (addr & 0xFFF) as intelfsh does.
   type tFlashMode is (FM_NORMAL, FM_ID1, FM_ID2, FM_AMDID, FM_ERASE1, FM_ERASE2, FM_ERASE3, FM_ERASING, FM_PROG);
   signal fl_mode_lo, fl_mode_hi     : tFlashMode := FM_NORMAL;
   -- erase status byte: DQ3=1 while erasing (intelfsh m_status = 1<<3); DQ6|DQ2 toggle on
   -- every read (intelfsh.cpp:600). DQ7 stays 0 until done. 29F016A returns status at ALL
   -- addresses while erasing (intelfsh.cpp:584 Firebeat note - no erase-sector range check).
   signal fl_status_lo, fl_status_hi : std_logic_vector(7 downto 0) := x"08";
   -- op queue, 2 deep: a 16-bit program or a both-chips erase enqueues one op per lane.
   -- Flash software status-polls between operations, so depth 2 never overflows.
   type tOpAddr is array(0 to 1) of unsigned(23 downto 0);
   type tOpLen  is array(0 to 1) of unsigned(21 downto 0);
   type tOpData is array(0 to 1) of std_logic_vector(7 downto 0);
   signal opq_valid : std_logic_vector(1 downto 0) := "00";
   signal opq_fill  : std_logic_vector(1 downto 0) := "00";
   signal opq_lane  : std_logic_vector(1 downto 0) := "00";
   signal opq_addr  : tOpAddr := (others => (others => '0'));
   signal opq_len   : tOpLen  := (others => (others => '0'));
   signal opq_data  : tOpData := (others => (others => '0'));
   signal opq_rd, opq_wr : integer range 0 to 1 := 0;
   signal opq_any   : std_logic;
   signal fl_rdpend : std_logic := '0';   -- an array read is stalled awaiting a fresh DDR3 fetch
   signal fl_rd_mode : tFlashMode;        -- mode of the lane addressed by the current read byte

   -- intelfsh.cpp write_full, AMD subset for the 29F016A. Unknown bytes leave the mode
   -- unchanged in the NORMAL-family states and fall back to NORMAL mid-sequence, as MAME does.
   function flash_next_mode(m : tFlashMode; a : unsigned(11 downto 0); d : std_logic_vector(7 downto 0)) return tFlashMode is
   begin
      case m is
         when FM_NORMAL | FM_AMDID =>
            if    d = x"F0" or d = x"FF"      then return FM_NORMAL;   -- reset chip mode
            elsif d = x"90"                   then return FM_AMDID;    -- read ID
            elsif d = x"AA" and a = x"555"    then return FM_ID1;      -- unlock 1
            else                                   return m;
            end if;
         when FM_ID1 =>
            if d = x"55" and a = x"2AA" then return FM_ID2; else return FM_NORMAL; end if;
         when FM_ID2 =>
            if a = x"555" then
               if    d = x"90" then return FM_AMDID;
               elsif d = x"80" then return FM_ERASE1;
               elsif d = x"A0" then return FM_PROG;
               else                 return FM_NORMAL;
               end if;
            else return FM_NORMAL;
            end if;
         when FM_ERASE1 =>
            if d = x"AA" and a = x"555" then return FM_ERASE2; else return m; end if;
         when FM_ERASE2 =>
            if d = x"55" and a = x"2AA" then return FM_ERASE3; else return m; end if;
         when FM_ERASE3 =>
            if (d = x"10" and a = x"555") or d = x"30" then return FM_ERASING; else return m; end if;
         when FM_PROG    => return FM_NORMAL;   -- the data write was consumed (program op enqueued)
         when FM_ERASING => return FM_ERASING;  -- writes ignored while erasing; cleared on op completion
      end case;
   end function;

   -- CurrentButtons = buttons XOR 0xFFFFFFFF (konami.cpp KonamiButtonsSet)
   signal CurrentButtons : unsigned(31 downto 0);

   -- EEPROM (128 bytes) in M10K block RAM. Port A = EXP1 (byte); port B = HPS save mount (16-bit).
   signal ee_addr   : std_logic_vector(6 downto 0);
   signal ee_addr_q : std_logic_vector(6 downto 0) := (others => '1');  -- dpram-registered-address tracker (EEPROM read stall)
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
   signal loadedOnce   : std_logic := '0';  -- auto-load guard: one load per reset while mounted

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
   signal fetch_tout  : unsigned(21 downto 0) := (others => '0');  -- ~124ms @33.87MHz HPS-silence timeout
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
   signal dbg_pc_phase : unsigned(2 downto 0) := (others => '0');  -- cycles 0..6 over the 7 milestone bands
   signal dbg_pc_latch : unsigned(31 downto 0) := (others => '0');  -- PC snapshot (frozen at phase 0)
   signal scsi_seen    : std_logic := '0';  -- latched once the boot first touches SCSI (region 0)

   -- ===== MILESTONE PROBE (replaces the unreliable PC-reconstruction probe) =====
   -- Latch how far the boot progresses through the known DuckStation sequence, then emit the
   -- HIGHEST milestone reached over the disc-read channel (fd pos = ScsiSectorLba*2048):
   --   level 1 P1 read   (region 0x10) -> lba 0x1000 -> fd ~8MB   (reached pre-SCSI input poll)
   --   level 2 EEPROM    (region 0x18) -> lba 0x2000 -> fd ~16MB  (reached the EEPROM-W 0x20 pre-SCSI step)
   --   level 3 SCSI      (region 0x00) -> lba 0x3000 -> fd ~24MB  (entered the 53CF96 handshake)
   --   level 4 READ(10)  (CDB 0x28)    -> lba 0x4000 -> fd ~32MB  (issued the real disc command)
   --   fd == 0 -> never reached even P1 (stuck in early POST / core code).
   -- All lbas < the ISO's 24395 sectors. Fires only when the disc FSM is idle + no real read
   -- pending (discState=D_IDLE, dmaArmed=0, fetchStart=0), so it never corrupts a real READ(10):
   -- READ(10) arms dmaArmed in one cycle (gates the probe off) and its ScsiSectorLba assignment
   -- is later in the process (wins any same-cycle race).
   signal ms_p1        : std_logic := '0';  -- reached P1 input read    (region 0x10)
   signal ms_eeprom    : std_logic := '0';  -- reached EEPROM access    (region 0x18)
   signal ms_tball     : std_logic := '0';  -- reached trackball        (region 0x68, offset 0xC0-0xCF)
   signal ms_flash     : std_logic := '0';  -- reached flash window     (region 0x68, offset 0x80-0x8F)
   signal ms_read10    : std_logic := '0';  -- reached SCSI READ(10)    (CDB 0x28 decoded)
   -- Last-valid-PC (derail origin) snapshot: frozen when the PC first leaves valid range
   signal pc_last_valid : unsigned(31 downto 0) := (others => '0'); -- most recent in-range PC
   signal bad_pc        : unsigned(31 downto 0) := (others => '0'); -- first out-of-range PC (wild target)
   signal prev_valid    : std_logic := '0';
   signal captured      : std_logic := '0';                         -- derail captured (dbg_pc_latch = origin PC)

   -- ===== ACCESS-RING PROBE (#8): capture the LAST 16 EXP1 accesses before the game goes
   -- QUIET (no EXP1 access for ~0.5s = halted at the error screen), then emit each entry
   -- forever via marker LBAs: lba = "01" & idx(3:0) & rw & region(6:0) & offset(7:0) & bstep(1:0).
   -- The disc-fetch timeout serves the far-out marker reads (stale buffer) so the fd parks at
   -- lba*2048 long enough to poll. Entry idx=15 is replaced by the total CDB(0x42) count.
   -- entry (v2, value-carrying): type(2) [00=SCSI 01=EEPROM 10=flash 11=other] & reg/word idx(6)
   --                             & rw(1) & data(8) & bstep0(1)  = 18 bits
   type tRing is array(0 to 15) of std_logic_vector(17 downto 0);
   signal ring        : tRing := (others => (others => '0'));
   signal ring_wr     : unsigned(3 downto 0) := (others => '0');
   signal mouse_event_q : std_logic := '0';                        -- ps2_mouse toggle tracker (count each packet once)
   signal pend_valid  : std_logic := '0';                          -- 1-cycle-delayed capture (reads: grab served byte)
   signal pend_meta   : std_logic_vector(9 downto 0) := (others => '0');  -- type2 & idx6 & rw1 & bstep0
   signal pend_wdata  : std_logic_vector(7 downto 0) := (others => '0');
   signal ring_frozen : std_logic := '0';
   signal quiet_cnt   : unsigned(23 downto 0) := (others => '0');   -- ~0.5s @33.87MHz
   signal emit_idx    : unsigned(4 downto 0) := (others => '0');  -- 0-15 ring/cdb, 16 = IRQ10 diag, then wrap
   signal cdb_count   : unsigned(15 downto 0) := (others => '0');   -- total command-0x42 latches
   signal ring_seen   : std_logic := '0';                           -- any EXP1 access at all yet
   signal last_region : std_logic_vector(6 downto 0) := (others => '0');  -- region of the newest captured access
   signal diag_wait   : unsigned(28 downto 0) := (others => '0');   -- ~8s arm delay for the not-frozen diag heartbeat

begin

   region  <= to_integer(bus_addr(22 downto 16));
   scsiReg <= to_integer(bus_addr(4 downto 1));
   bsel    <= to_integer(bus_addr(1 downto 0));
   CurrentButtons <= buttons xor x"FFFFFFFF";

   -- P1 inputs assembled combinationally (active-low), per konami.cpp bit masks +
   -- konamigv.cpp operator inputs: 0x400 COIN1, 0x800 SERVICE1, 0x1000 TEST switch
   -- (PORT_SERVICE_NO_TOGGLE). Bit 13 = EEPROM DO line -- stays '1' (konami.cpp).
   p1val(31 downto 13) <= (others => '1');
   p1val(12) <= '0' when (CurrentButtons(2) = '1') else '1';  -- TEST  (0x1000, OSD Service Mode level)
   p1val(11) <= '0' when (CurrentButtons(1) = '1') else '1';  -- SERVICE1 (0x800, pad R2)
   p1val(10) <= '0' when (CurrentButtons(0) = '1') else '1';  -- COIN1 (0x400, pad Select)
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
   -- konami.cpp sub-word semantics (KonamiEepromRead, konami.cpp:395-406 + bus.cpp applies NO
   -- byte-lane fixup to EXP1 device reads): the handler returns the full 16-bit word for ANY
   -- access size/offset, so a BYTE read at an ODD offset yields the word's LOW byte and a 32-bit
   -- read yields the word ZERO-EXTENDED. Replicate by addressing the byte lane with the
   -- CPU-access byte-step (bus_bstep), NOT the address bit 0: word index = bus_addr(6:1),
   -- byte-within-word = bstep(0). Writes keep address-based lanes (write path byte-steps are
   -- mask-seeded and equal the address lanes for the 16-bit stores the game uses).
   -- Read address composed ONLY from early-stable signals (bus_addr(6:2) is stable from
   -- access start; bit1 of the bus address arrives late in the lane arithmetic, so use the
   -- raw access address bit via bus_a10 instead): word = bus_addr(6:2) & a10(1), lane = bstep(0).
   -- No stall needed -> no stall-restart hazard (ring probe #12).
   -- Read-form is the DEFAULT (so the dpram's registered address is already settled a cycle
   -- before the read strobe); the write-form (true byte address) applies only during the write
   -- strobe itself, which is fine because dpram writes take address+data+wren on the same edge.
   ee_addr <= std_logic_vector(bus_addr(6 downto 0)) when bus_write = '1'
              else std_logic_vector(bus_addr(6 downto 2)) & bus_a10(1) & bus_bstep(0);
   -- registered copy: ee_addr_q == ee_addr means the dpram's registered address (and thus q_a)
   -- reflects the live bus address; used by the bus_exp1_wait EEPROM stall term.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if ce = '1' then
            ee_addr_q <= ee_addr;
         end if;
      end if;
   end process;
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
         clock_a => clk1x, address_a => buf_addr_a, data_a => (others => '0'), q_a => buf_q_a,  -- port A: read-only
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

   -- Fix A: the old prefetch assumed the slow EXP1 bus hid the DDR3 latency -- false (tb_flash),
   -- so the loader's tight read loop got STALE flash data. Now a flash-data-port read STALLS
   -- (bus_exp1_wait) until the DDR3 FSM publishes the word for THIS FlashAddress (flash_rdaddr ==
   -- FlashAddress). Level-based compare = clk1x/clk2x-CDC-safe (no fragile ready pulse).
   -- (EEPROM stall REMOVED, build #13: since the sub-word semantics fix, the EEPROM dpram
   -- address is bus_addr(6:1) & bstep(0) -- the word index is stable from access start and
   -- the byte-step settles between strobes, so q_a is always valid by the capture edge with
   -- no stall. The stall had become a hardware hazard: ring probe #12 showed the security
   -- decision's EEPROM word-2 read arriving as TWO bstep0=0 strobes (suspected stall-induced
   -- access restart -> assembled 0x0808 instead of 0x0F08 -> wrong game ID).
   -- 29F016A additions: only ARRAY reads touch DDR3 and stall. ID (FM_AMDID) and erase-status
   -- (FM_ERASING) reads are served from registers - stalling those would deadlock the game's
   -- status-poll loop against a multi-ms erase fill. Array reads additionally stall while
   -- write ops are queued/in flight (opq_any) so a read never returns pre-program data; the
   -- psx_top FSM invalidates flash_rdaddr after every op, forcing a fresh fetch.
   fl_rd_mode <= fl_mode_lo when bus_addr(0) = '0' else fl_mode_hi;
   bus_exp1_wait <= '1' when (bus_read = '1' and region = 16#68# and
                              bus_addr(7 downto 4) = "1000" and bus_addr(3 downto 1) = "000" and
                              fl_rd_mode /= FM_AMDID and fl_rd_mode /= FM_ERASING and
                              (opq_any = '1' or flash_rdaddr /= std_logic_vector(FlashAddress))) else
                    '0';

   -- Fetch request to psx_top: LEVEL, not pulse (a pulse would be lost when a stalled read
   -- must wait behind queued write ops - the fetch may only run after the ops drain, long
   -- after the read strobe). psx_top edge-detects; ops are held off the fetch by opq_any.
   opq_any     <= opq_valid(0) or opq_valid(1);
   flash_fetch <= fl_rdpend and not opq_any;

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
            loadedOnce   <= '0';
         else
            if eeprom_load = '1' then loadLatched <= '1'; end if;
            if eeprom_save = '1' then saveLatched <= '1'; end if;

            case eepState is
               when EE_IDLE =>
                  -- loadedOnce: the MGL mounts S0 while the core is still held in reset by the
                  -- flash ioctl download (reset_or includes flash_download), so the 1-cycle
                  -- eeprom_load pulse is swallowed and loadLatched stays clear -> the game would
                  -- read an all-zeros EEPROM (checksum 0==0 passes, security code fails).
                  -- konami.cpp loads the EEPROM file before emulation starts (KonamiInit,
                  -- konami.cpp:114-126); mirror that by auto-loading once whenever a mount is
                  -- present and we haven't loaded since reset.
                  if ((loadLatched = '1' or loadedOnce = '0') and eeprom_mounted = '1') then
                     eeprom_rd   <= '1';
                     eep_loading <= '1';
                     loadLatched <= '0';
                     loadedOnce  <= '1';
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
      variable v_pcphys   : unsigned(28 downto 0);
      variable v_pcvalid  : std_logic;

      -- enqueue a 29F016A program/erase op at the write pointer. Depth-2 cannot overflow in
      -- practice (flash software status-polls between operations); a full queue drops the op.
      procedure flash_enqueue(fill : std_logic; addr : unsigned(23 downto 0); len : unsigned(21 downto 0);
                              data : std_logic_vector(7 downto 0); lane : std_logic) is
      begin
         if opq_valid(opq_wr) = '0' then
            opq_valid(opq_wr) <= '1';
            opq_fill(opq_wr)  <= fill;
            opq_lane(opq_wr)  <= lane;
            opq_addr(opq_wr)  <= addr;
            opq_len(opq_wr)   <= len;
            opq_data(opq_wr)  <= data;
            opq_wr            <= 1 - opq_wr;
            -- synthesis translate_off
            report "DBG ENQ slot=" & integer'image(opq_wr) & " fill=" & std_logic'image(fill) & " lane=" & std_logic'image(lane) severity note;
            -- synthesis translate_on
         end if;
      end procedure;
   begin
      if rising_edge(clk1x) then

         irq10_set   <= '0';  -- default: assert is a one-cycle pulse
         v_tbreset   := '0';

         if reset = '1' then
            ScsiFifoPtr  <= 0;
            ScsiIsRead   <= '0';
            FlashAddress <= (others => '0');
            fl_mode_lo   <= FM_NORMAL;
            fl_mode_hi   <= FM_NORMAL;
            fl_status_lo <= x"08";
            fl_status_hi <= x"08";
            opq_valid    <= "00";
            opq_rd       <= 0;
            opq_wr       <= 0;
            flash_op_req <= '0';
            fl_rdpend    <= '0';
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
            scsi_seen    <= '0';
            ms_p1        <= '0';
            ms_eeprom    <= '0';
            ms_tball     <= '0';
            ms_flash     <= '0';
            ms_read10    <= '0';
            captured     <= '0';
            prev_valid   <= '0';
            ring_wr      <= (others => '0');
            ring_frozen  <= '0';
            quiet_cnt    <= (others => '0');
            emit_idx     <= (others => '0');
            cdb_count    <= (others => '0');
            ring_seen    <= '0';
            last_region  <= (others => '0');
            diag_wait    <= (others => '0');
            pend_valid   <= '0';
            TrackballX   <= (others => '0');
            TrackballY   <= (others => '0');

         elsif ce = '1' then

            ------------------------------------------------------------------
            -- MILESTONE PROBE (#22): emit highest boot milestone over disc channel.
            -- LBA encoding (fd = LBA*2048):
            --   0x0001 → fd ~2KB  = alive, no EXP1 milestone yet
            --   0x1000 → fd ~8MB  = P1 input read    (region 0x10)
            --   0x2000 → fd ~16MB = EEPROM access     (region 0x18)
            --   0x3000 → fd ~24MB = flash/trackball   (region 0x68)
            --   0x4000 → fd ~32MB = SCSI region read  (region 0x00)
            --   0x5000 → fd ~40MB = SCSI READ(10)     (CDB 0x28)
            -- Fires every 2^DBG_PC_CNT_BITS cycles when disc FSM is idle.
            ------------------------------------------------------------------
            dbg_pc_cnt <= dbg_pc_cnt + 1;
            -- Probe disabled once game issues real READ(10): avoid corrupting bufferValid for game DMA.
            if (dbg_pc_cnt = 0 and discState = D_IDLE and dmaArmed = '0' and fetchStart = '0' and ms_read10 = '0') then
               fetchStart <= '1'; bufferValid <= '0';
               if scsi_seen = '1' then
                  ScsiSectorLba <= to_unsigned(16#4000#,32);
               elsif ms_tball = '1' or ms_flash = '1' then
                  ScsiSectorLba <= to_unsigned(16#3000#,32);
               elsif ms_eeprom = '1' then
                  ScsiSectorLba <= to_unsigned(16#2000#,32);
               elsif ms_p1 = '1' then
                  ScsiSectorLba <= to_unsigned(16#1000#,32);
               else
                  ScsiSectorLba <= to_unsigned(16#0001#,32);
               end if;
            end if;

            ------------------------------------------------------------------
            -- ACCESS-RING PROBE (#8): capture EXP1 accesses; freeze on ~0.5s of
            -- EXP1 silence after the game reached disc loading (= halted at the
            -- error screen); then emit the ring via marker LBAs forever. The
            -- fetch timeout completes the far-out marker reads with stale data.
            ------------------------------------------------------------------
            -- Filter watchdog (0x78), P1/P2 (0x10), AND the trackball window (0x68/0xC0-0xCF)
            -- out of capture and quiet detection: the halted game's input loop polls the
            -- trackball every ~100ms forever (probe #10 diag: region 0x68 spam, ring_wr cycling),
            -- which floods the ring and prevents the freeze. Flash (0x68/0x80-0x8F) stays visible.
            -- Stage 1: on a capturable access, latch metadata (+write data); stage 2: commit to
            -- the ring one cycle later so READ entries can grab the byte our core actually
            -- served (bus_dataRead is registered by then and holds until the next access).
            -- Split filters (#15): quiet-freeze keyed ONLY on meaningful traffic (SCSI/EEPROM/
            -- flash) going silent; the ring CAPTURES everything except the watchdog, so the
            -- frozen ring also shows the P1/trackball VALUES the game read at the decision.
            pend_valid <= '0';
            if ((bus_read = '1' or bus_write = '1') and region /= 16#78#) then
               if (region /= 16#10# and not (region = 16#68# and bus_addr(7 downto 4) = "1100")) then
                  quiet_cnt <= (others => '0');
                  ring_seen <= '1';
               end if;
               last_region <= std_logic_vector(bus_addr(22 downto 16));
               if ring_frozen = '0' then
                  pend_valid <= '1';
                  pend_wdata <= bus_dataWrite;
                  if region = 16#00# then
                     pend_meta <= "00" & "00" & std_logic_vector(bus_addr(4 downto 1)) & bus_write & bus_bstep(0);
                  elsif region = 16#18# then
                     pend_meta <= "01" & std_logic_vector(bus_addr(6 downto 1)) & bus_write & bus_bstep(0);
                  elsif region = 16#68# then
                     -- idx6 bit5 = addr(6): 1 = trackball window (0xC0+), 0 = flash (0x80+)
                     pend_meta <= "10" & bus_addr(6) & '0' & std_logic_vector(bus_addr(3 downto 0)) & bus_write & bus_bstep(0);
                  else
                     pend_meta <= "11" & std_logic_vector(bus_addr(5 downto 0)) & bus_write & bus_bstep(0);
                  end if;
               end if;
            elsif (ms_read10 = '1' and ring_seen = '1' and ring_frozen = '0') then
               quiet_cnt <= quiet_cnt + 1;
               if quiet_cnt = (quiet_cnt'range => '1') then
                  ring_frozen <= '1';
               end if;
            end if;

            if pend_valid = '1' and ring_frozen = '0' then
               -- entry = type2 & idx6 & rw1 & data8 & bstep0 (reads: data = byte just served)
               if pend_meta(1) = '1' then   -- rw bit
                  ring(to_integer(ring_wr)) <= pend_meta(9 downto 2) & pend_wdata &
                                               pend_meta(1) & pend_meta(0);
               else
                  ring(to_integer(ring_wr)) <= pend_meta(9 downto 2) & bus_dataRead &
                                               pend_meta(1) & pend_meta(0);
               end if;
               ring_wr <= ring_wr + 1;
            end if;

            if ms_read10 = '1' and diag_wait /= (diag_wait'range => '1') then
               diag_wait <= diag_wait + 1;   -- saturating ~8s arm delay after disc loading begins
            end if;

            -- Emission: dmaArmed deliberately NOT required (probe #9 lesson: a stuck armed
            -- transfer at the halt must not silence telemetry). fetchStart/discState guards
            -- keep the HPS handshake itself consistent.
            if (dbg_pc_cnt = 0 and discState = D_IDLE and fetchStart = '0') then
               if ring_frozen = '1' then
                  fetchStart  <= '1'; bufferValid <= '0';
                  if emit_idx = 16 then
                     -- IRQ10 delivery diag: "10" & rise(7:0) & fall(7:0) & "000000"
                     ScsiSectorLba <= unsigned(std_logic_vector'(x"00" & "10" &
                                               std_logic_vector(irq10_rise_cnt) &
                                               std_logic_vector(irq10_fall_cnt) & "000000"));
                     emit_idx <= (others => '0');
                  else
                     if emit_idx = 15 then
                        ScsiSectorLba <= unsigned(std_logic_vector'(x"00" & "011111" & "00" &
                                                  std_logic_vector(cdb_count)));
                     else
                        -- oldest-first: entry order = ring_wr + emit_idx (ring_wr points past newest)
                        ScsiSectorLba <= unsigned(std_logic_vector'(x"00" & "01" & std_logic_vector(emit_idx(3 downto 0)) &
                                                  ring(to_integer(ring_wr + emit_idx(3 downto 0)))));
                     end if;
                     emit_idx <= emit_idx + 1;
                  end if;
               elsif diag_wait = (diag_wait'range => '1') then
                  -- not frozen long after disc loading: report WHO keeps resetting the quiet
                  -- counter. lba = "10" & last_region(6:0) & ring_wr(3:0) & quiet_cnt(23:13)
                  fetchStart  <= '1'; bufferValid <= '0';
                  ScsiSectorLba <= unsigned(std_logic_vector'(x"00" & "10" & last_region &
                                            std_logic_vector(ring_wr) &
                                            std_logic_vector(quiet_cnt(23 downto 13))));
               end if;
            end if;

            ------------------------------------------------------------------
            -- READ
            ------------------------------------------------------------------
            bus_dataRead <= (others => '1');
            if bus_read = '1' then
               case region is
                  when 16#00# =>                                   -- SCSI 0x000000-0x00001F
                     scsi_seen    <= '1';
                     bus_dataRead <= ScsiRegs(scsiReg);
                     if scsiReg = REG_FIFO then
                        bus_dataRead <= (others => '0');
                     elsif scsiReg = REG_IRQSTATE then
                        ScsiRegs(REG_STATUS) <= ScsiRegs(REG_STATUS) and x"7F";  -- clear bit 0x80
                     end if;

                  when 16#10# =>                                   -- P1 0x100000 / P2 0x100004
                     ms_p1 <= '1';
                     if bus_addr(2) = '1' then
                        bus_dataRead <= (others => '1');            -- P2 = 0xFF
                     else
                        -- lane by CPU-access byte-step, not address (konami.cpp returns the full
                        -- Value for any size/offset; a byte read at ANY offset sees bits 0-7)
                        case to_integer(unsigned(bus_bstep)) is
                           when 0      => bus_dataRead <= p1val(7  downto  0);
                           when 1      => bus_dataRead <= p1val(15 downto  8);
                           when 2      => bus_dataRead <= p1val(23 downto 16);
                           when others => bus_dataRead <= p1val(31 downto 24);
                        end case;
                     end if;

                  when 16#18# =>                                   -- EEPROM 0x180080-0x1800FF
                     ms_eeprom <= '1';
                     if bus_bstep(1) = '1' then
                        bus_dataRead <= (others => '0');           -- 32-bit read upper half: konami.cpp zero-extends the u16
                     else
                        bus_dataRead <= ee_q;
                     end if;

                  when 16#68# =>                                   -- flash 0x6800{80..8F} / trackball 0x6800{C0..C9}
                     if bus_addr(7 downto 4) = "1100" then         -- 0xC0..0xCF trackball window
                        ms_tball <= '1';
                        if bus_addr(3) = '0' then                  -- 0xC0..0xC7 data (axis in HIGH byte, low byte 0)
                           -- konami.cpp positions the axis in bits 8-15 of the returned Value;
                           -- lane by byte-step (bstep 1 = the axis byte; 0/2/3 = zero)
                           if bus_bstep = "01" then
                              case to_integer(bus_addr(2 downto 1)) is
                                 when 0      => bus_dataRead <= std_logic_vector(TrackballX(7 downto 0));            -- C0 hi
                                 when 1      => bus_dataRead <= "0000" & std_logic_vector(TrackballX(11 downto 8));  -- C2 hi
                                 when 2      => bus_dataRead <= std_logic_vector(TrackballY(7 downto 0));            -- C4 hi
                                 when others => bus_dataRead <= "0000" & std_logic_vector(TrackballY(11 downto 8));  -- C6 hi
                              end case;
                           else
                              bus_dataRead <= (others => '0');     -- lanes 0/2/3: konami.cpp Value has zeros there
                           end if;
                        else                                       -- 0xC8 (konami.cpp default case) -> zero counters
                           v_tbreset := '1';
                        end if;
                     elsif bus_addr(7 downto 4) = "1000" then      -- 0x80..0x8F flash data port
                        ms_flash <= '1';
                        if bus_addr(3 downto 1) = "000" then        -- offset 0: 16-bit interleaved word
                           -- Value by chip mode (intelfsh.cpp read_full): AMDID -> maker/device ID,
                           -- ERASING -> toggling status byte, everything else (incl. mid-unlock-
                           -- sequence states) falls to the NORMAL array read, as MAME's default does.
                           if bus_addr(0) = '0' then
                              case fl_mode_lo is
                                 when FM_AMDID =>
                                    if    FlashAddress(7 downto 0) = x"00" then bus_dataRead <= x"04"; -- MFG_FUJITSU
                                    elsif FlashAddress(7 downto 0) = x"01" then bus_dataRead <= x"AD"; -- 29F016A
                                    else                                        bus_dataRead <= x"00";
                                    end if;
                                 when FM_ERASING =>
                                    bus_dataRead <= fl_status_lo;              -- DQ7=0 busy; DQ6|DQ2 toggle per read
                                    fl_status_lo <= fl_status_lo xor x"44";
                                 when others =>
                                    bus_dataRead <= flash_data(7 downto 0);    -- array: low byte (Flash[Chip])
                                    -- fix A (level form): request a DDR3 fetch of the CURRENT word;
                                    -- bus_exp1_wait holds the read until flash_rdaddr == FlashAddress
                                    -- AND all write ops have drained (ops invalidate flash_rdaddr).
                                    if flash_rdaddr /= std_logic_vector(FlashAddress) or opq_any = '1' then
                                       fl_rdpend <= '1';
                                    end if;
                              end case;
                           else
                              case fl_mode_hi is
                                 when FM_AMDID =>
                                    if    FlashAddress(7 downto 0) = x"00" then bus_dataRead <= x"04";
                                    elsif FlashAddress(7 downto 0) = x"01" then bus_dataRead <= x"AD";
                                    else                                        bus_dataRead <= x"00";
                                    end if;
                                 when FM_ERASING =>
                                    bus_dataRead <= fl_status_hi;
                                    fl_status_hi <= fl_status_hi xor x"44";
                                 when others =>
                                    bus_dataRead <= flash_data(15 downto 8);   -- array: high byte (Flash[Chip+1])
                              end case;
                              FlashAddress <= FlashAddress + 1;                -- FA++ after the high byte (GV glue, mode-independent)
                           end if;
                        elsif bus_addr(3 downto 1) = "100" then     -- offset 8: FA |= 1
                           bus_dataRead <= (others => '0');
                           FlashAddress <= FlashAddress or to_unsigned(1, FlashAddress'length);
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
                                 cdb_count <= cdb_count + 1;   -- probe telemetry: total commands latched
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
                                       ms_read10  <= '1';            -- MILESTONE: reached the real disc READ(10)
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

                  when 16#68# =>                                   -- flash address writes (0x82/0x84/0x86)
                     -- konami.cpp (KonamiFlashWrite, konami.cpp:369-391) gets ONE call with the
                     -- full 16-bit Value: wr@2 FA=Val<<1 (reaches bit16), wr@4 |=Val<<8 (bit23),
                     -- wr@6 |=Val<<15 (bit30). Our bus byte-steps 16-bit writes, so the high
                     -- byte used to be DROPPED (odd offsets fell into "others=>null") -- any FA
                     -- set with a nonzero high byte seeked the wrong flash address. Fix: apply
                     -- the op on the even byte (konami.cpp byte-write behavior), then on the
                     -- second byte-step (bstep=01) REAPPLY it with the reassembled 16-bit value
                     -- {hi,lo}; algebra over the masks makes the double-apply equal konami.cpp's
                     -- single 16-bit op for all three registers.
                     if bus_addr(7 downto 4) = "1000" then         -- flash window only (not trackball 0xC0+)
                        -- NOTE: write-path byteStep is the lane within the 32-bit WORD (a 16-bit
                        -- write @+2 arrives with bsteps 2,3), so pair even/odd bytes by bstep(0).
                        if bus_bstep(0) = '0' then
                           fl_wr_lo <= unsigned(bus_dataWrite);    -- low byte of a possible 16-bit access
                           case to_integer(bus_addr(3 downto 0)) is
                              when 0 =>
                                 -- data port, LO chip (konamigv.cpp flash_w case 0, data & 0xFF).
                                 -- Actions fire off the PRE-transition mode (intelfsh order).
                                 if fl_mode_lo = FM_PROG then
                                    flash_enqueue('0', FlashAddress, to_unsigned(0, 22), bus_dataWrite, '0');
                                 elsif fl_mode_lo = FM_ERASE3 then
                                    if bus_dataWrite = x"10" and FlashAddress(11 downto 0) = x"555" then
                                       flash_enqueue('1', (FlashAddress and to_unsigned(16#200000#, 24)),         -- chip erase: whole 2MB lane
                                                     to_unsigned(16#200000#, 22), x"FF", '0');
                                    elsif bus_dataWrite = x"30" then
                                       flash_enqueue('1', (FlashAddress and to_unsigned(16#3F0000#, 24)),         -- 64KB sector erase
                                                     to_unsigned(16#010000#, 22), x"FF", '0');
                                    end if;
                                 end if;
                                 fl_mode_lo <= flash_next_mode(fl_mode_lo, FlashAddress(11 downto 0), bus_dataWrite);
                                 fl_status_lo <= x"08";
                                 -- synthesis translate_off
                                 report "DBG LOWR data=" & to_hstring(bus_dataWrite) & " FA=" & to_hstring(FlashAddress) & " mode=" & tFlashMode'image(fl_mode_lo) severity note;
                                 -- synthesis translate_on
                              when 2 => FlashAddress <= shift_left(resize(unsigned(bus_dataWrite), 24), 1);
                              when 4 => FlashAddress <= (FlashAddress and to_unsigned(16#FF00FF#, 24)) or
                                                        shift_left(resize(unsigned(bus_dataWrite), 24), 8);
                              when 6 => FlashAddress <= (FlashAddress and to_unsigned(16#00FFFF#, 24)) or
                                                        shift_left(resize(unsigned(bus_dataWrite), 24), 15);
                              when others => null;
                           end case;
                        else                                       -- 2nd byte of a 16-bit write: reapply with {hi,lo}
                           case to_integer(bus_addr(3 downto 0)) is
                              when 1 =>
                                 -- data port, HI chip (konamigv.cpp flash_w case 0, data >> 8).
                                 -- NOT a reapply: MAME issues exactly one write() per chip, and the
                                 -- byte-stepped bus hands us exactly one byte per chip. FA unchanged.
                                 if fl_mode_hi = FM_PROG then
                                    flash_enqueue('0', FlashAddress, to_unsigned(0, 22), bus_dataWrite, '1');
                                 elsif fl_mode_hi = FM_ERASE3 then
                                    if bus_dataWrite = x"10" and FlashAddress(11 downto 0) = x"555" then
                                       flash_enqueue('1', (FlashAddress and to_unsigned(16#200000#, 24)),
                                                     to_unsigned(16#200000#, 22), x"FF", '1');
                                    elsif bus_dataWrite = x"30" then
                                       flash_enqueue('1', (FlashAddress and to_unsigned(16#3F0000#, 24)),
                                                     to_unsigned(16#010000#, 22), x"FF", '1');
                                    end if;
                                 end if;
                                 fl_mode_hi <= flash_next_mode(fl_mode_hi, FlashAddress(11 downto 0), bus_dataWrite);
                                 fl_status_hi <= x"08";
                                 -- synthesis translate_off
                                 report "DBG HIWR data=" & to_hstring(bus_dataWrite) & " FA=" & to_hstring(FlashAddress) & " mode=" & tFlashMode'image(fl_mode_hi) severity note;
                                 -- synthesis translate_on
                              when 3 => FlashAddress <= resize(shift_left(resize(unsigned(bus_dataWrite) & fl_wr_lo, 25), 1), 24);
                              when 5 => FlashAddress <= (FlashAddress and to_unsigned(16#FF00FF#, 24)) or
                                                        resize(shift_left(resize(unsigned(bus_dataWrite) & fl_wr_lo, 32), 8), 24);
                              when 7 => FlashAddress <= (FlashAddress and to_unsigned(16#00FFFF#, 24)) or
                                                        resize(shift_left(resize(unsigned(bus_dataWrite) & fl_wr_lo, 39), 15), 24);
                              when others => null;
                           end case;
                        end if;
                     end if;

                  when others => null;
               end case;
            end if;

            ------------------------------------------------------------------
            -- 29F016A op dispatch: hand the oldest queued program/erase to the
            -- psx_top memFlash FSM over the 4-phase level handshake. Placed
            -- AFTER the bus write handler so an erase-completion mode clear
            -- wins over a same-cycle (ignored) write to the erasing chip.
            ------------------------------------------------------------------
            if flash_op_req = '0' and flash_op_done = '0' and opq_valid(opq_rd) = '1' then
               flash_op_fill <= opq_fill(opq_rd);
               flash_op_lane <= opq_lane(opq_rd);
               flash_op_addr <= std_logic_vector(opq_addr(opq_rd));
               flash_op_len  <= opq_len(opq_rd);
               flash_op_data <= opq_data(opq_rd);
               flash_op_req  <= '1';
               -- synthesis translate_off
               report "DBG DISPATCH slot=" & integer'image(opq_rd) severity note;
               -- synthesis translate_on
            elsif flash_op_req = '1' and flash_op_done = '1' then
               flash_op_req      <= '0';
               opq_valid(opq_rd) <= '0';
               opq_rd            <= 1 - opq_rd;
               -- synthesis translate_off
               report "DBG OPDONE slot=" & integer'image(opq_rd) severity note;
               -- synthesis translate_on
               -- Leave ERASING lanes in status mode until the WHOLE queue drains: a both-chips
               -- erase runs as two serialized fills, and clearing the first lane early turns
               -- its half of every status poll into an ARRAY read that stalls behind the
               -- second fill (multi-ms bus stall per poll; found by tb_flash_write). Clearing
               -- on queue-empty keeps both DQ7s busy until all fills land - which is also what
               -- the software's "poll until both chips ready" loop expects.
               if opq_valid(1 - opq_rd) = '0' then
                  if fl_mode_lo = FM_ERASING then fl_mode_lo <= FM_NORMAL; end if;
                  if fl_mode_hi = FM_ERASING then fl_mode_hi <= FM_NORMAL; end if;
               end if;
            end if;

            -- release the pending-fetch level once the stalled array read can complete
            if fl_rdpend = '1' and opq_any = '0' and flash_rdaddr = std_logic_vector(FlashAddress) then
               fl_rdpend <= '0';
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
                  disc_lba   <= std_logic_vector(ScsiSectorLba(30 downto 0)) & blkIdx;  -- lba*2 + blkIdx
                  disc_req   <= '1';
                  fetch_tout <= (others => '0');
                  discState  <= D_WAITSTART;

               when D_WAITSTART =>
                  fetch_tout <= fetch_tout + 1;
                  if disc_ack = '1' then
                     discState <= D_WAITDONE;
                  elsif fetch_tout = (fetch_tout'range => '1') then
                     -- HPS never serviced this block (e.g. out-of-range LBA -> EOF, nothing
                     -- to deliver). konami.cpp completes such reads with whatever is in its
                     -- stale Sector[] buffer (konami.cpp:166-171, fread!=2048 tolerated, the
                     -- error log at :169 is commented out upstream). Serve the buffer as-is
                     -- and complete instead of hanging the game forever.
                     disc_req    <= '0';
                     bufferValid <= '1';
                     discState   <= D_IDLE;
                  end if;

               when D_WAITDONE =>
                  fetch_tout <= fetch_tout + 1;
                  if disc_ack = '0' then                          -- block now resident in buffer
                     if blkIdx = '0' then
                        blkIdx    <= '1';
                        discState <= D_REQ;
                     else
                        bufferValid <= '1';
                        discState   <= D_IDLE;
                     end if;
                  elsif fetch_tout = (fetch_tout'range => '1') then
                     disc_req    <= '0';                          -- same stale-serve escape as D_WAITSTART
                     bufferValid <= '1';
                     discState   <= D_IDLE;
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
            elsif mouse_event /= mouse_event_q then
               -- mouse_event is the hps_io ps2_mouse[24] TOGGLE (flips once per packet), NOT a
               -- pulse: level-accumulating added each delta every ce cycle the toggle sat high
               -- (~16M adds/packet -> instant +/-2048 saturation = "hypersensitive Y, dead X").
               -- Count each packet ONCE (either edge) and scale by the OSD trackball speed.
               if tball_invert(0) = '1' then
                  v_tx := resize(TrackballX, 13) - resize(shift_right(mouse_x, to_integer(unsigned(tball_speed))), 13);
               else
                  v_tx := resize(TrackballX, 13) + resize(shift_right(mouse_x, to_integer(unsigned(tball_speed))), 13);
               end if;
               if tball_invert(1) = '1' then
                  v_ty := resize(TrackballY, 13) - resize(shift_right(mouse_y, to_integer(unsigned(tball_speed))), 13);
               else
                  v_ty := resize(TrackballY, 13) + resize(shift_right(mouse_y, to_integer(unsigned(tball_speed))), 13);
               end if;
               if    v_tx >  2047 then TrackballX <= to_signed( 2047, 12);
               elsif v_tx < -2048 then TrackballX <= to_signed(-2048, 12);
               else                    TrackballX <= resize(v_tx, 12); end if;
               if    v_ty >  2047 then TrackballY <= to_signed( 2047, 12);
               elsif v_ty < -2048 then TrackballY <= to_signed(-2048, 12);
               else                    TrackballY <= resize(v_ty, 12); end if;
            end if;
            mouse_event_q <= mouse_event;

         end if;
      end if;
   end process;

end architecture;
