library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use std.textio.all;

-- Replays the WORKING DuckStation 573 SCSI boot handshake (DUCKSTATION_573_BOOT_TRACE.md)
-- into konami573.vhd to find where the MiSTer core stalls before READ(10)/disc_req.
--
-- KEY: we drive bus_addr = the REAL EXP1 byte offset (e.g. reg5/IRQSTATE = 0x0A). That is
-- exactly what the FIXED memorymux now delivers (exp1_byte_lane = byteStep + addr(1:0) on reads).
-- So this isolates konami573's own logic: if it reaches disc_req with the right LBA given correct
-- addressing, the memorymux fix is sufficient; if it still stalls, there is a SECOND bug here.
--
-- Self-checks the STATUS/INTSTATE/IRQSTATE register contract at each step. Does NOT stop on a
-- failed check (severity warning) so every divergence in one run is visible. A monitor prints
-- every disc_req / irq10_set / exp_dmaRequest event with disc_lba.

entity tb_konami573_boot is end entity;

architecture sim of tb_konami573_boot is
   signal clk1x     : std_logic := '0';
   signal ce        : std_logic := '1';
   signal reset     : std_logic := '1';

   signal bus_addr      : unsigned(22 downto 0) := (others => '0');
   signal bus_dataWrite : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_read      : std_logic := '0';
   signal bus_write     : std_logic := '0';
   signal bus_dataRead  : std_logic_vector(7 downto 0);

   signal irq10_set        : std_logic;
   signal DMA_EXP_read     : std_logic_vector(31 downto 0);
   signal DMA_EXP_readEna  : std_logic := '0';
   signal exp_dmaRequest   : std_logic;
   signal exp_dmaDataValid : std_logic;
   signal dma5_done        : std_logic := '0';

   signal disc_req     : std_logic;
   signal disc_lba     : std_logic_vector(31 downto 0);
   signal disc_ack     : std_logic := '0';
   signal disc_wr      : std_logic := '0';
   signal disc_addr    : std_logic_vector(8 downto 0) := (others => '0');
   signal disc_data    : std_logic_vector(15 downto 0) := (others => '0');
   signal disc_mounted : std_logic := '1';   -- a disc IS mounted (S4)

   signal flash_word_addr  : std_logic_vector(23 downto 0);
   signal flash_fetch      : std_logic;
   signal flash_data       : std_logic_vector(15 downto 0) := (others => '0');
   signal flash_data_ready : std_logic := '0';

   signal eeprom_load    : std_logic := '0';
   signal eeprom_save    : std_logic := '0';
   signal eeprom_mounted : std_logic := '0';
   signal eeprom_rd      : std_logic;
   signal eeprom_wr      : std_logic;
   signal eeprom_ack     : std_logic := '0';
   signal eeprom_write   : std_logic := '0';
   signal eeprom_addr    : std_logic_vector(8 downto 0) := (others => '0');
   signal eeprom_dataIn  : std_logic_vector(15 downto 0) := (others => '0');
   signal eeprom_dataOut : std_logic_vector(15 downto 0);

   signal buttons     : unsigned(31 downto 0) := (others => '0');
   signal mouse_event : std_logic := '0';
   signal mouse_x     : signed(8 downto 0) := (others => '0');
   signal mouse_y     : signed(8 downto 0) := (others => '0');

   signal sim_done : std_logic := '0';
   signal cpu_pc_tb : unsigned(31 downto 0) := x"BFC01234";  -- DEBUG probe test PC

   -- SCSI register byte offsets (offset = reg*2; reg = (off & 0x1F) >> 1)
   constant OFF_XCNTLO : integer := 16#00#;  -- reg0
   constant OFF_XCNTMI : integer := 16#02#;  -- reg1
   constant OFF_FIFO   : integer := 16#04#;  -- reg2
   constant OFF_CMD    : integer := 16#06#;  -- reg3
   constant OFF_STATUS : integer := 16#08#;  -- reg4 (r=STATUS / w=destID)
   constant OFF_IRQST  : integer := 16#0A#;  -- reg5 (r=IRQSTATE / w=timeout)  <-- the bug register
   constant OFF_INTST  : integer := 16#0C#;  -- reg6 (r=INTSTATE / w=syncperiod)
   constant OFF_FIFOST : integer := 16#0E#;  -- reg7
   constant OFF_CTRL1  : integer := 16#10#;  -- reg8
   constant OFF_CLKF   : integer := 16#12#;  -- reg9
   constant OFF_CTRL2  : integer := 16#16#;  -- reg11
   constant OFF_CTRL3  : integer := 16#18#;  -- reg12
   constant OFF_CTRL4  : integer := 16#1A#;  -- reg13
   constant OFF_XCNTHI : integer := 16#1C#;  -- reg14

begin

   clk1x <= not clk1x after 5 ns when sim_done = '0' else '0';

   dut : entity work.konami573
      generic map ( DBG_PC_CNT_BITS => 6 )   -- fire fast for sim
      port map (
         clk1x => clk1x, ce => ce, reset => reset,
         bus_addr => bus_addr, bus_dataWrite => bus_dataWrite,
         bus_read => bus_read, bus_write => bus_write, bus_dataRead => bus_dataRead,
         irq10_set => irq10_set,
         DMA_EXP_read => DMA_EXP_read, DMA_EXP_readEna => DMA_EXP_readEna,
         exp_dmaRequest => exp_dmaRequest, exp_dmaDataValid => exp_dmaDataValid, dma5_done => dma5_done,
         disc_req => disc_req, disc_lba => disc_lba, disc_ack => disc_ack,
         disc_wr => disc_wr, disc_addr => disc_addr, disc_data => disc_data, disc_mounted => disc_mounted,
         flash_word_addr => flash_word_addr, flash_fetch => flash_fetch,
         flash_data => flash_data, flash_data_ready => flash_data_ready,
         eeprom_load => eeprom_load, eeprom_save => eeprom_save, eeprom_mounted => eeprom_mounted,
         eeprom_rd => eeprom_rd, eeprom_wr => eeprom_wr, eeprom_ack => eeprom_ack,
         eeprom_write => eeprom_write, eeprom_addr => eeprom_addr,
         eeprom_dataIn => eeprom_dataIn, eeprom_dataOut => eeprom_dataOut,
         buttons => buttons, mouse_event => mouse_event, mouse_x => mouse_x, mouse_y => mouse_y,
         cpu_pc => cpu_pc_tb
      );

   ----------------------------------------------------------------------------
   -- Monitor: print disc_req / irq10_set / exp_dmaRequest edges with context.
   ----------------------------------------------------------------------------
   monitor : process
      variable l : line;
      variable prev_discreq, prev_irq, prev_dmareq : std_logic := '0';
   begin
      wait until rising_edge(clk1x);
      if disc_req = '1' and prev_discreq = '0' then
         write(l, string'("  [MON] disc_req HIGH  disc_lba=0x"));
         hwrite(l, disc_lba);
         write(l, string'("  (= sector lba ") );
         write(l, integer'image(to_integer(unsigned(disc_lba)) / 2));
         write(l, string'(", block ")); write(l, integer'image(to_integer(unsigned(disc_lba)) mod 2));
         write(l, string'(")")); writeline(output, l);
      end if;
      if irq10_set = '1' and prev_irq = '0' then
         write(l, string'("  [MON] irq10_set pulse")); writeline(output, l);
      end if;
      if exp_dmaRequest = '1' and prev_dmareq = '0' then
         write(l, string'("  [MON] exp_dmaRequest HIGH (dmaArmed)")); writeline(output, l);
      end if;
      prev_discreq := disc_req; prev_irq := irq10_set; prev_dmareq := exp_dmaRequest;
   end process;

   ----------------------------------------------------------------------------
   -- Disc HPS responder: when disc_req rises, ack and stream 512 16-bit words
   -- (disc_addr 0..511) into the sector buffer (exactly like the MiSTer sd_* path).
   -- Pattern: word = lba(7..0) in hi byte, addr(7..0) in lo byte (recognizable).
   ----------------------------------------------------------------------------
   disc_hps : process
   begin
      disc_ack <= '0'; disc_wr <= '0'; disc_addr <= (others => '0'); disc_data <= (others => '0');
      loop
         wait until rising_edge(clk1x) and disc_req = '1';
         exit when sim_done = '1';
         for c in 0 to 2 loop wait until rising_edge(clk1x); end loop;  -- HPS latency
         disc_ack <= '1';
         for w in 0 to 511 loop
            disc_addr <= std_logic_vector(to_unsigned(w, 9));
            disc_data <= disc_lba(7 downto 0) & std_logic_vector(to_unsigned(w mod 256, 8));
            disc_wr   <= '1';
            wait until rising_edge(clk1x);
         end loop;
         disc_wr  <= '0';
         disc_ack <= '0';
      end loop;
   end process;

   -- SNAPSHOT TEST: change cpu_pc right after the first PC-probe read (phase 0).
   -- If the snapshot works, phases 1+2 still emit slices of the ORIGINAL 0xBFC01234
   -- (disc_lba 0x1C00 then 0x217E), NOT the new 0x8001ABCD (which would give 0x101A/0x2100).
   pc_change : process begin
      wait until rising_edge(clk1x) and disc_req = '1';   -- first probe read = phase 0 (snapshot taken)
      for i in 0 to 3 loop wait until rising_edge(clk1x); end loop;
      cpu_pc_tb <= x"8001ABCD";
      wait;
   end process;

   ----------------------------------------------------------------------------
   -- Stimulus: replay the boot trace with contract self-checks.
   ----------------------------------------------------------------------------
   stim : process
      variable nfail : integer := 0;
      variable nchk  : integer := 0;
      variable rd    : std_logic_vector(7 downto 0);
      variable l     : line;

      procedure step(s : string) is
         variable ll : line;
      begin
         write(ll, string'("--- ") & s); writeline(output, ll);
      end procedure;

      procedure bus_wr(off : integer; data : integer) is
      begin
         wait until falling_edge(clk1x);
         bus_addr      <= to_unsigned(off, 23);
         bus_dataWrite <= std_logic_vector(to_unsigned(data, 8));
         bus_write     <= '1';
         wait until rising_edge(clk1x);   -- write commits here
         wait until falling_edge(clk1x);
         bus_write     <= '0';
      end procedure;

      procedure bus_rd(off : integer; result : out std_logic_vector(7 downto 0)) is
      begin
         wait until falling_edge(clk1x);
         bus_addr <= to_unsigned(off, 23);
         bus_read <= '1';
         wait until rising_edge(clk1x);   -- bus_dataRead registers here
         wait until falling_edge(clk1x);  -- settled
         result   := bus_dataRead;
         bus_read <= '0';
      end procedure;

      -- read register `off`, compare to `exp`, log PASS/FAIL (non-fatal)
      procedure chk(off : integer; exp : integer; name : string) is
         variable r  : std_logic_vector(7 downto 0);
         variable ll : line;
      begin
         bus_rd(off, r);
         nchk := nchk + 1;
         if to_integer(unsigned(r)) = exp then
            write(ll, string'("  PASS ") & name & string'(" = 0x"));
            hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x"));
            hwrite(ll, r);
            write(ll, string'(" expected 0x"));
            hwrite(ll, std_logic_vector(to_unsigned(exp, 8)));
            writeline(output, ll);
         end if;
      end procedure;

      -- push one FIFO byte
      procedure fifo(b : integer) is begin bus_wr(OFF_FIFO, b); end procedure;
   begin
      -- reset
      reset <= '1';
      for i in 0 to 5 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      wait until falling_edge(clk1x);

      ------------------------------------------------------------------ DEBUG PC-PROBE CHECK
      step("DEBUG: PC probe (cpu_pc=0xBFC01234) -> expect disc reads at ScsiSectorLba 0x48D / 0xE01 / 0x10BF");
      for i in 0 to 4000 loop wait until rising_edge(clk1x); end loop;  -- let the 3 PC phases cycle

      ------------------------------------------------------------------ PHASE 1
      step("PHASE 1: reset handshake (CMD 0x00,0x02,0x00)");
      bus_wr(OFF_CMD, 16#00#);
      bus_wr(OFF_CMD, 16#02#);   -- STATUS|=0x80, IRQ
      bus_wr(OFF_CMD, 16#00#);
      chk(OFF_STATUS, 16#80#, "STATUS(after 0x02)");
      chk(OFF_INTST,  16#00#, "INTSTATE");
      chk(OFF_IRQST,  16#08#, "IRQSTATE");          -- this read clears STATUS 0x80
      chk(OFF_STATUS, 16#00#, "STATUS(post IRQSTATE-read)");

      ------------------------------------------------------------------ PHASE 2
      step("PHASE 2: reg8/CTRL1 self-test echo (sampled)");
      bus_wr(OFF_CTRL1, 16#00#); chk(OFF_CTRL1, 16#00#, "CTRL1 echo 0x00");
      bus_wr(OFF_CTRL1, 16#55#); chk(OFF_CTRL1, 16#55#, "CTRL1 echo 0x55");
      bus_wr(OFF_CTRL1, 16#AA#); chk(OFF_CTRL1, 16#AA#, "CTRL1 echo 0xAA");
      bus_wr(OFF_CTRL1, 16#FF#); chk(OFF_CTRL1, 16#FF#, "CTRL1 echo 0xFF");

      ------------------------------------------------------------------ PHASE 3
      step("PHASE 3: controller config + CMD 0x03");
      bus_wr(OFF_STATUS, 16#04#);  -- destID (write to reg4, dropped from STATUS)
      bus_wr(OFF_CTRL1,  16#16#);
      bus_wr(OFF_CTRL2,  16#48#);
      bus_wr(OFF_CTRL3,  16#E7#);
      bus_wr(OFF_CTRL4,  16#00#);
      bus_wr(OFF_CLKF,   16#04#);
      bus_wr(OFF_IRQST,  16#7A#);  -- timeout (reg5 write, dropped)
      bus_wr(OFF_FIFOST, 16#00#);  -- syncoffset (reg7 write, dropped)
      bus_wr(OFF_INTST,  16#05#);  -- syncperiod (reg6 write, dropped)
      bus_wr(OFF_CMD,    16#03#);
      chk(OFF_STATUS, 16#00#, "STATUS(after 0x03)");
      chk(OFF_INTST,  16#04#, "INTSTATE(after 0x03)");
      chk(OFF_IRQST,  16#08#, "IRQSTATE(after 0x03)");

      ------------------------------------------------------------------ PHASE 4
      step("PHASE 4: READ(10) lba 16 -- CDB 28 00 00 00 00 10 00 00 01 00");
      bus_wr(OFF_CMD,    16#44#);  -- nop/setup
      bus_wr(OFF_STATUS, 16#04#);  -- destID
      fifo(16#80#);                -- identify
      fifo(16#28#); fifo(16#00#); fifo(16#00#); fifo(16#00#); fifo(16#00#);
      fifo(16#10#); fifo(16#00#); fifo(16#00#); fifo(16#01#); fifo(16#00#);
      bus_wr(OFF_CMD, 16#42#);     -- select+send CDB -> latch LBA, STATUS=0x01, IRQ, arm fetch
      chk(OFF_STATUS, 16#01#, "STATUS(after 0x42)");
      chk(OFF_INTST,  16#04#, "INTSTATE(after 0x42)");
      chk(OFF_IRQST,  16#08#, "IRQSTATE(after 0x42)");
      chk(OFF_STATUS, 16#01#, "STATUS(after 0x42, reread)");

      -- transfer byte count writes (clear STATUS 0x10; stays 0x01)
      bus_wr(OFF_XCNTHI, 16#00#);
      bus_wr(OFF_XCNTMI, 16#08#);
      bus_wr(OFF_XCNTLO, 16#00#);

      step("PHASE 4: waiting for disc fetch to complete (bufferValid)");
      -- exp_dmaDataValid follows bufferValid while ScsiIsRead=1; wait for it (with timeout).
      for i in 0 to 4000 loop
         exit when exp_dmaDataValid = '1';
         wait until rising_edge(clk1x);
      end loop;
      if exp_dmaDataValid = '1' then
         write(l, string'("  PASS sector buffered: exp_dmaDataValid=1 (disc READ path reached & completed)"));
      else
         nfail := nfail + 1;
         write(l, string'("  **FAIL** exp_dmaDataValid never asserted -- disc fetch did not complete"));
      end if;
      writeline(output, l);

      step("PHASE 4: DMA drain (read 4 words via DMA_EXP_readEna)");
      for k in 0 to 3 loop
         wait until falling_edge(clk1x);
         DMA_EXP_readEna <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         write(l, string'("    word ")); write(l, integer'image(k));
         write(l, string'(" DMA_EXP_read=0x")); hwrite(l, DMA_EXP_read);
         writeline(output, l);
         DMA_EXP_readEna <= '0';
      end loop;

      step("PHASE 4: DMA completion (pulse dma5_done) then post handshake 0x90/0x11/0x12");
      wait until falling_edge(clk1x);
      dma5_done <= '1';
      wait until rising_edge(clk1x);
      wait until falling_edge(clk1x);
      dma5_done <= '0';
      chk(OFF_STATUS, 16#00#, "STATUS(after dma5_done, &0xF8)");

      bus_wr(OFF_CMD, 16#90#);  -- 0x10|0x80
      chk(OFF_STATUS, 16#03#, "STATUS(after 0x90)");
      chk(OFF_INTST,  16#00#, "INTSTATE(after 0x90)");
      chk(OFF_IRQST,  16#08#, "IRQSTATE(after 0x90)");
      chk(OFF_STATUS, 16#03#, "STATUS(after 0x90, reread)");

      bus_wr(OFF_CMD, 16#11#);  -- -> STATUS=0x80, INTSTATE=0x06
      chk(OFF_STATUS, 16#80#, "STATUS(after 0x11)");
      chk(OFF_INTST,  16#06#, "INTSTATE(after 0x11)");
      chk(OFF_IRQST,  16#08#, "IRQSTATE(after 0x11)");   -- clears STATUS 0x80
      chk(OFF_STATUS, 16#00#, "STATUS(post IRQSTATE-read)");

      bus_wr(OFF_CMD, 16#12#);  -- -> STATUS|=0x80, INTSTATE=0x06
      chk(OFF_STATUS, 16#80#, "STATUS(after 0x12)");
      chk(OFF_INTST,  16#06#, "INTSTATE(after 0x12)");

      ------------------------------------------------------------------ SUMMARY
      step("SUMMARY");
      write(l, string'("  checks: ")); write(l, integer'image(nchk));
      write(l, string'("   failures: ")); write(l, integer'image(nfail));
      writeline(output, l);
      if nfail = 0 then
         write(l, string'("  RESULT: ALL CONTRACT CHECKS PASS -- konami573 reaches READ(10)/disc_req with correct addressing."));
      else
         write(l, string'("  RESULT: DIVERGENCE FOUND -- see **FAIL** lines above."));
      end if;
      writeline(output, l);

      for i in 0 to 20 loop wait until rising_edge(clk1x); end loop;
      sim_done <= '1';
      wait for 50 ns;
      finish;
   end process;

end architecture;
