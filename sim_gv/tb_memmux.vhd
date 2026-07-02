library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use std.textio.all;

-- END-TO-END EXP1 DELIVERY TEST: drives the 573 SCSI handshake as CPU byte accesses through
-- the REAL memorymux.vhd (with the byte-lane fix) into the REAL konami573.vhd. This is the gap
-- the konami573-only sim could not cover: it proves the CPU->memctrl->memorymux->EXP1 chain
-- actually delivers byte WRITES (SCSI commands/FIFO) and byte READS (STATUS/IRQSTATE) to konami573
-- with the right register/byte, and that konami573 then reaches disc_req.
--
-- CPU model: drive mem_in_* (addressData=0x1F0000xx, reqsize=00 byte). Writes processed directly
-- from IDLE; reads complete on mem_done with the addressed byte in mem_dataRead(7:0).

entity tb_memmux is end entity;

architecture sim of tb_memmux is
   signal clk1x, clk2x, ce, reset : std_logic := '0';
   signal sim_done : std_logic := '0';

   -- CPU-side bus
   signal mem_in_request, mem_in_rnw, mem_in_isData, mem_in_isCache : std_logic := '0';
   signal mem_in_oldtagvalids : std_logic_vector(3 downto 0) := "0000";
   signal mem_in_addressInstr : unsigned(31 downto 0) := (others => '0');
   signal mem_in_addressData  : unsigned(31 downto 0) := (others => '0');
   signal mem_in_reqsize      : unsigned(1 downto 0) := "00";
   signal mem_in_writeMask    : std_logic_vector(3 downto 0) := "0000";
   signal mem_in_dataWrite    : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_dataRead        : std_logic_vector(31 downto 0);
   signal mem_done            : std_logic;
   signal mem_fifofull        : std_logic;
   signal mem_tagvalids       : std_logic_vector(3 downto 0);
   signal isIdle              : std_logic;

   -- EXP1 wires between memorymux and konami573
   signal bus_exp1_addr      : unsigned(22 downto 0);
   signal bus_exp1_dataWrite : std_logic_vector(7 downto 0);
   signal bus_exp1_read      : std_logic;
   signal bus_exp1_write     : std_logic;
   signal bus_exp1_dataRead  : std_logic_vector(7 downto 0);
   signal bus_exp1_wait      : std_logic;   -- fix-A device stall (flash + EEPROM read latency)
   signal bus_exp1_bstep     : std_logic_vector(1 downto 0);  -- CPU-access byte-step (konami.cpp lane semantics)
   signal bus_exp1_a10       : std_logic_vector(1 downto 0);

   -- konami573 extra ports
   signal irq10_set        : std_logic;
   signal DMA_EXP_read     : std_logic_vector(31 downto 0);
   signal exp_dmaRequest   : std_logic;
   signal exp_dmaDataValid : std_logic;
   signal disc_req         : std_logic;
   signal disc_lba         : std_logic_vector(31 downto 0);
   signal disc_ack_s       : std_logic := '0';
   signal seen_lba20       : std_logic := '0';   -- real READ(10) lba16 fetch observed (lba*2 = 0x20/0x21)
   signal flash_word_addr  : std_logic_vector(23 downto 0);
   signal flash_fetch      : std_logic;
   signal eeprom_rd, eeprom_wr : std_logic;
   signal eeprom_dataOut   : std_logic_vector(15 downto 0);

   -- tie-offs for the many unused memorymux buses (outputs left open)
   signal z32 : std_logic_vector(31 downto 0) := (others => '0');
   signal z16 : std_logic_vector(15 downto 0) := (others => '0');
   signal z8  : std_logic_vector(7 downto 0)  := (others => '0');
   constant MEMCTRL_EXP1 : unsigned(13 downto 0) := to_unsigned(16#263F#, 14); -- =0x0013243F low14: width=0 (8-bit), Float/Hold set
   -- the GAME's EXP1 reconfig value: MEMCTRL write 0x173F47 at pc 0x80064E80; low 14 bits,
   -- bit12 SET = 16-bit bus width (the security-check era configuration)
   constant MEMCTRL_EXP1_W16 : unsigned(13 downto 0) := to_unsigned(16#3F47#, 14);
   signal ex1_memctrl_s : unsigned(13 downto 0) := MEMCTRL_EXP1;
   constant COMD : unsigned(3 downto 0) := to_unsigned(1, 4);

   -- SCSI byte offsets within EXP1 (0x1F000000 base)
   constant BASE     : unsigned(31 downto 0) := x"1F000000";
   constant OFF_FIFO : integer := 16#04#;
   constant OFF_CMD  : integer := 16#06#;
   constant OFF_STAT : integer := 16#08#;
   constant OFF_IRQ  : integer := 16#0A#;
   constant OFF_INT  : integer := 16#0C#;

begin
   clk1x <= not clk1x after 5 ns when sim_done = '0' else '0';
   clk2x <= not clk2x after 2500 ps when sim_done = '0' else '0';
   ce    <= '1';

   imux : entity work.memorymux
      port map (
         clk1x => clk1x, clk2x => clk2x, ce => ce, reset => reset,
         pauseNext => '0', isIdle => isIdle,
         loadExe => '0', exe_initial_pc => (others=>'0'), exe_initial_gp => (others=>'0'),
         exe_load_address => (others=>'0'), exe_file_size => (others=>'0'), exe_stackpointer => (others=>'0'),
         reset_exe => open,
         fastboot => '0', PATCHSERIAL => '0', TURBO => '0', region_in => "00",
         ram_dataWrite => open, ram_dataRead => z32, ram_Adr => open, ram_be => open,
         ram_rnw => open, ram_ena => open, ram_cache => open, ram_done => '1',
         mem_in_request => mem_in_request, mem_in_rnw => mem_in_rnw, mem_in_isData => mem_in_isData,
         mem_in_isCache => mem_in_isCache, mem_in_oldtagvalids => mem_in_oldtagvalids,
         mem_in_addressInstr => mem_in_addressInstr, mem_in_addressData => mem_in_addressData,
         mem_in_reqsize => mem_in_reqsize, mem_in_writeMask => mem_in_writeMask,
         mem_in_dataWrite => mem_in_dataWrite, mem_dataRead => mem_dataRead, mem_done => mem_done,
         mem_fifofull => mem_fifofull, mem_tagvalids => mem_tagvalids,
         bios_memctrl => MEMCTRL_EXP1,
         ex1_memctrl => ex1_memctrl_s,
         bus_exp1_addr => bus_exp1_addr, bus_exp1_dataWrite => bus_exp1_dataWrite,
         bus_exp1_read => bus_exp1_read, bus_exp1_write => bus_exp1_write, bus_exp1_dataRead => bus_exp1_dataRead,
         bus_exp1_wait => bus_exp1_wait, bus_exp1_bstep => bus_exp1_bstep, bus_exp1_a10 => bus_exp1_a10,
         bus_memc_addr => open, bus_memc_dataWrite => open, bus_memc_read => open, bus_memc_write => open, bus_memc_dataRead => z32,
         bus_pad_addr => open, bus_pad_dataWrite => open, bus_pad_read => open, bus_pad_write => open, bus_pad_writeMask => open, bus_pad_dataRead => z32,
         bus_sio_addr => open, bus_sio_dataWrite => open, bus_sio_read => open, bus_sio_write => open, bus_sio_writeMask => open, bus_sio_dataRead => z32,
         bus_memc2_addr => open, bus_memc2_dataWrite => open, bus_memc2_read => open, bus_memc2_write => open, bus_memc2_dataRead => z32,
         bus_irq_addr => open, bus_irq_dataWrite => open, bus_irq_read => open, bus_irq_write => open, bus_irq_dataRead => z32,
         bus_dma_addr => open, bus_dma_dataWrite => open, bus_dma_read => open, bus_dma_write => open, bus_dma_dataRead => z32,
         bus_tmr_addr => open, bus_tmr_dataWrite => open, bus_tmr_read => open, bus_tmr_write => open, bus_tmr_dataRead => z32,
         cd_memctrl => MEMCTRL_EXP1,
         bus_cd_addr => open, bus_cd_dataWrite => open, bus_cd_read => open, bus_cd_write => open, bus_cd_dataRead => z8,
         bus_gpu_addr => open, bus_gpu_dataWrite => open, bus_gpu_read => open, bus_gpu_write => open, bus_gpu_dataRead => z32, bus_gpu_stall => '0',
         bus_mdec_addr => open, bus_mdec_dataWrite => open, bus_mdec_read => open, bus_mdec_write => open, bus_mdec_dataRead => z32,
         spu_memctrl => MEMCTRL_EXP1,
         bus_spu_addr => open, bus_spu_dataWrite => open, bus_spu_read => open, bus_spu_write => open, bus_spu_dataRead => z16,
         ex2_memctrl => MEMCTRL_EXP1,
         bus_exp2_addr => open, bus_exp2_dataWrite => open, bus_exp2_read => open, bus_exp2_write => open, bus_exp2_dataRead => z8,
         ex3_memctrl => MEMCTRL_EXP1,
         bus_exp3_read => open, bus_exp3_dataRead => z16,
         com0_delay => COMD, com1_delay => COMD, com2_delay => COMD, com3_delay => COMD,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others=>'0'),
         SS_Adr => (others=>'0'), SS_wren_SDRam => '0', SS_rden_SDRam => '0'
      );

   ikonami : entity work.konami573
      port map (
         clk1x => clk1x, ce => ce, reset => reset,
         bus_addr => bus_exp1_addr, bus_dataWrite => bus_exp1_dataWrite,
         bus_read => bus_exp1_read, bus_write => bus_exp1_write, bus_dataRead => bus_exp1_dataRead,
         bus_exp1_wait => bus_exp1_wait, bus_bstep => bus_exp1_bstep, bus_a10 => bus_exp1_a10,
         irq10_set => irq10_set,
         DMA_EXP_read => DMA_EXP_read, DMA_EXP_readEna => '0',
         exp_dmaRequest => exp_dmaRequest, exp_dmaDataValid => exp_dmaDataValid, dma5_done => '0',
         disc_req => disc_req, disc_lba => disc_lba, disc_ack => disc_ack_s,
         disc_wr => '0', disc_addr => (others=>'0'), disc_data => (others=>'0'), disc_mounted => '1',
         flash_word_addr => flash_word_addr, flash_fetch => flash_fetch,
         flash_data => (others=>'0'), flash_data_ready => '0',
         eeprom_load => '0', eeprom_save => '0', eeprom_mounted => '0',
         eeprom_rd => eeprom_rd, eeprom_wr => eeprom_wr, eeprom_ack => '0',
         eeprom_write => '0', eeprom_addr => (others=>'0'), eeprom_dataIn => (others=>'0'),
         eeprom_dataOut => eeprom_dataOut,
         buttons => (others=>'0'), mouse_event => '0', mouse_x => (others=>'0'), mouse_y => (others=>'0')
      );

   -- HPS ack model: complete every disc_req after a short delay so probe marker fetches
   -- (milestone probe fires an "alive" fetch at lba 1 on the first cycle) drain instead of
   -- wedging the disc FSM; latch when the REAL lba16 read (disc_lba 0x20/0x21) comes through.
   ack_model : process
   begin
      wait until rising_edge(clk1x);
      if disc_req = '1' and disc_ack_s = '0' then
         if unsigned(disc_lba) = 16#20# or unsigned(disc_lba) = 16#21# then seen_lba20 <= '1'; end if;
         for i in 1 to 3 loop wait until rising_edge(clk1x); end loop;
         disc_ack_s <= '1';
         for i in 1 to 4 loop wait until rising_edge(clk1x); end loop;
         disc_ack_s <= '0';
      end if;
   end process;

   -- monitor flash-window write strobes (temporary diagnostic)
   fwmon : process (clk1x)
      variable ll : line;
   begin
      if rising_edge(clk1x) then
         if bus_exp1_write = '1' and bus_exp1_addr(22 downto 16) = "1101000" then  -- region 0x68
            write(ll, string'("  [FW] addr=")); hwrite(ll, std_logic_vector(bus_exp1_addr(7 downto 0)));
            write(ll, string'(" bstep=") & integer'image(to_integer(unsigned(bus_exp1_bstep))));
            write(ll, string'(" data=")); hwrite(ll, bus_exp1_dataWrite);
            writeline(output, ll);
         end if;
      end if;
   end process;

   -- monitor disc_req
   monitor : process
      variable l : line;
      variable prev : std_logic := '0';
   begin
      wait until rising_edge(clk1x);
      if disc_req = '1' and prev = '0' then
         write(l, string'("  [MON] disc_req HIGH  disc_lba=0x")); hwrite(l, disc_lba);
         write(l, string'("  (sector lba ")); write(l, integer'image(to_integer(unsigned(disc_lba))/2));
         write(l, string'(", blk ")); write(l, integer'image(to_integer(unsigned(disc_lba)) mod 2)); write(l, string'(")"));
         writeline(output, l);
      end if;
      prev := disc_req;
   end process;

   stim : process
      variable nfail, nchk : integer := 0;
      variable l : line;

      procedure tick(n : integer) is begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      -- CPU byte WRITE of val to EXP1 offset off
      procedure cwr(off : integer; val : integer) is
         variable lane : integer := off mod 4;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_dataWrite   <= std_logic_vector(to_unsigned(val, 8)) & std_logic_vector(to_unsigned(val,8)) &
                               std_logic_vector(to_unsigned(val,8)) & std_logic_vector(to_unsigned(val,8)); -- val in every lane (mux picks by byteStep)
         mem_in_writeMask   <= std_logic_vector(to_unsigned(2**lane, 4));
         mem_in_reqsize     <= "00";
         mem_in_rnw         <= '0';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);   -- IDLE captures + goes to BUSWRITEEXTERNAL
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         -- wait for the access to complete (FSM leaves IDLE, then returns)
         for i in 0 to 60 loop wait until rising_edge(clk1x); exit when isIdle = '0'; end loop;
         for i in 0 to 200 loop wait until rising_edge(clk1x); exit when isIdle = '1'; end loop;
      end procedure;

      -- CPU byte READ of EXP1 offset off; check low byte against exp
      procedure crd_chk(off : integer; exp : integer; name : string) is
         variable r : std_logic_vector(7 downto 0);
         variable ll : line;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_reqsize     <= "00";
         mem_in_rnw         <= '1';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);   -- IDLE latches read into mem_save
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         r := (others => 'U');
         for i in 0 to 200 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then r := mem_dataRead(7 downto 0); exit; end if;
         end loop;
         nchk := nchk + 1;
         if to_integer(unsigned(r)) = exp then
            write(ll, string'("  PASS ") & name & string'(" = 0x")); hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x")); hwrite(ll, r);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp,8))); writeline(output, ll);
         end if;
      end procedure;

      -- CPU 16-bit READ of EXP1 offset off; check low 16 bits against exp
      procedure crd16_chk(off : integer; exp : integer; name : string) is
         variable r : std_logic_vector(15 downto 0);
         variable ll : line;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_reqsize     <= "01";
         mem_in_rnw         <= '1';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         r := (others => 'U');
         for i in 0 to 300 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then r := mem_dataRead(15 downto 0); exit; end if;
         end loop;
         nchk := nchk + 1;
         if to_integer(unsigned(r)) = exp then
            write(ll, string'("  PASS ") & name & string'(" = 0x")); hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x")); hwrite(ll, r);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp,16))); writeline(output, ll);
         end if;
      end procedure;

      -- CPU 32-bit READ of EXP1 offset off; check all 32 bits against exp
      procedure crd32_chk(off : integer; exp : integer; name : string) is
         variable r : std_logic_vector(31 downto 0);
         variable ll : line;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_reqsize     <= "10";
         mem_in_rnw         <= '1';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         r := (others => 'U');
         for i in 0 to 500 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then r := mem_dataRead; exit; end if;
         end loop;
         nchk := nchk + 1;
         if r = std_logic_vector(to_unsigned(exp, 32)) then
            write(ll, string'("  PASS ") & name & string'(" = 0x")); hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x")); hwrite(ll, r);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp,32))); writeline(output, ll);
         end if;
      end procedure;

      -- CPU 16-bit WRITE of val to EXP1 offset off (must be 2-byte aligned)
      procedure cwr16(off : integer; val : integer) is
         variable lane : integer := off mod 4;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_dataWrite   <= std_logic_vector(to_unsigned(val, 16)) & std_logic_vector(to_unsigned(val, 16));
         mem_in_writeMask   <= std_logic_vector(to_unsigned(3 * (2**lane), 4));
         mem_in_reqsize     <= "01";
         mem_in_rnw         <= '0';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         for i in 0 to 60 loop wait until rising_edge(clk1x); exit when isIdle = '0'; end loop;
         for i in 0 to 300 loop wait until rising_edge(clk1x); exit when isIdle = '1'; end loop;
      end procedure;

      -- check FlashAddress via the flash_word_addr port (writes drain via the memorymux
      -- write FIFO after the CPU-side completes -- allow time for all byte strobes)
      procedure fa_chk(exp : integer; name : string) is
         variable ll : line;
      begin
         for i in 1 to 80 loop wait until rising_edge(clk1x); end loop;
         nchk := nchk + 1;
         if flash_word_addr = std_logic_vector(to_unsigned(exp, 24)) then
            write(ll, string'("  PASS ") & name & string'(" FA=0x")); hwrite(ll, flash_word_addr); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : FA=0x")); hwrite(ll, flash_word_addr);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp, 24))); writeline(output, ll);
         end if;
      end procedure;

      procedure step(s : string) is variable ll : line; begin
         write(ll, string'("--- ") & s); writeline(output, ll); end procedure;
   begin
      reset <= '1'; tick(8); wait until falling_edge(clk1x); reset <= '0'; tick(2);

      step("PHASE 0: reg8/CTRL1 self-test echo through memorymux (the FIRST thing the BIOS does)");
      cwr(16#10#, 16#00#); crd_chk(16#10#, 16#00#, "CTRL1 echo 0x00");
      cwr(16#10#, 16#55#); crd_chk(16#10#, 16#55#, "CTRL1 echo 0x55");
      cwr(16#10#, 16#AA#); crd_chk(16#10#, 16#AA#, "CTRL1 echo 0xAA");
      cwr(16#10#, 16#FF#); crd_chk(16#10#, 16#FF#, "CTRL1 echo 0xFF");
      cwr(16#10#, 16#16#); crd_chk(16#10#, 16#16#, "CTRL1 echo 0x16");

      step("PHASE 1: reset handshake CMD 0x00/0x02/0x00 then read STATUS/IRQSTATE through memorymux");
      cwr(OFF_CMD, 16#00#);
      cwr(OFF_CMD, 16#02#);    -- STATUS|=0x80, IRQ
      cwr(OFF_CMD, 16#00#);
      crd_chk(OFF_STAT, 16#80#, "STATUS(after 0x02)");
      crd_chk(OFF_IRQ,  16#08#, "IRQSTATE  <-- the reg5 byte-lane fix");   -- clears STATUS 0x80
      crd_chk(OFF_STAT, 16#00#, "STATUS(post IRQSTATE read)");

      step("PHASE 2: config CMD 0x03 then read INTSTATE");
      cwr(OFF_CMD, 16#03#);    -- INTSTATE=0x04, IRQ
      crd_chk(OFF_INT,  16#04#, "INTSTATE(after 0x03)");
      crd_chk(OFF_IRQ,  16#08#, "IRQSTATE(after 0x03)");

      step("PHASE 3: READ(10) lba16 -- FIFO writes + CMD 0x42 through memorymux, expect disc_req");
      cwr(OFF_CMD, 16#44#);                       -- nop
      cwr(OFF_FIFO, 16#80#);                      -- identify
      cwr(OFF_FIFO, 16#28#); cwr(OFF_FIFO, 16#00#); cwr(OFF_FIFO, 16#00#); cwr(OFF_FIFO, 16#00#);
      cwr(OFF_FIFO, 16#00#); cwr(OFF_FIFO, 16#10#); cwr(OFF_FIFO, 16#00#); cwr(OFF_FIFO, 16#00#);
      cwr(OFF_FIFO, 16#01#); cwr(OFF_FIFO, 16#00#);
      cwr(OFF_CMD, 16#42#);                       -- select+send CDB -> latch LBA, arm fetch
      crd_chk(OFF_STAT, 16#01#, "STATUS(after 0x42)");
      crd_chk(OFF_INT,  16#04#, "INTSTATE(after 0x42)");

      step("PHASE 3: wait for the lba16 disc fetch (proves WRITE delivery reached konami573 SCSI FSM)");
      for i in 0 to 600 loop exit when seen_lba20 = '1'; wait until rising_edge(clk1x); end loop;
      nchk := nchk + 1;
      if seen_lba20 = '1' then
         write(l, string'("  PASS real READ(10) fetch observed (disc_lba 0x20 = lba16*2; probe markers skipped)"));
      else
         nfail := nfail + 1;
         write(l, string'("  **FAIL** lba16 fetch never observed -- write delivery did NOT reach konami573"));
      end if;
      writeline(output, l);

      step("PHASE 4: EEPROM round-trip through memorymux (write bytes, read back as bytes AND 16-bit)");
      -- seed 6 bytes at EEPROM offsets 0..5 (EXP1 0x180080..85)
      cwr(16#180080#, 16#11#); cwr(16#180081#, 16#22#); cwr(16#180082#, 16#33#);
      cwr(16#180083#, 16#44#); cwr(16#180084#, 16#55#); cwr(16#180085#, 16#66#);
      -- konami.cpp semantics: a byte read at ANY offset returns the addressed WORD's LOW byte
      -- (handler returns the full u16, bus applies no lane fixup, CPU masks &0xFF)
      crd_chk(16#180080#, 16#11#, "EEPROM byte rd @80");
      crd_chk(16#180081#, 16#11#, "EEPROM byte rd @81 (konami.cpp: word0 LOW byte)");
      crd_chk(16#180082#, 16#33#, "EEPROM byte rd @82 (word1 low)");
      crd_chk(16#180083#, 16#33#, "EEPROM byte rd @83 (konami.cpp: word1 LOW byte)");
      crd16_chk(16#180080#, 16#2211#, "EEPROM 16-bit rd @80 (word0)");
      crd16_chk(16#180082#, 16#4433#, "EEPROM 16-bit rd @82 (word1)");
      crd16_chk(16#180084#, 16#6655#, "EEPROM 16-bit rd @84 (word2)");
      -- 32-bit read: konami.cpp returns the u16 word ZERO-EXTENDED (upper half = 0)
      crd32_chk(16#180080#, 16#00002211#, "EEPROM 32-bit rd @80 (zero-extended word0)");
      crd32_chk(16#180084#, 16#00006655#, "EEPROM 32-bit rd @84 (zero-extended word2)");
      -- stale-latency trap: unrelated SCSI read immediately before an EEPROM read
      cwr(16#10#, 16#5A#);                       -- park a known value in CTRL1
      crd_chk(16#10#, 16#5A#, "CTRL1 park");
      crd16_chk(16#180080#, 16#2211#, "EEPROM 16-bit rd @80 right after SCSI read (stale trap)");
      crd_chk(16#180084#, 16#55#, "EEPROM byte rd @84 right after 16-bit read (stale trap 2)");

      step("PHASE 5: flash-address 16-bit writes (konami.cpp math incl. HIGH byte; the boot only used byte values)");
      cwr(16#680082#, 16#40#);       fa_chk(16#000080#, "byte wr@82 0x40 -> FA=0x80 (boot pattern)");
      cwr16(16#680082#, 16#1234#);   fa_chk(16#002468#, "16-bit wr@82 0x1234 -> FA=Val<<1");
      cwr16(16#680084#, 16#ABCD#);   fa_chk(16#ABCD68#, "16-bit wr@84 0xABCD -> (FA&FF00FF)|Val<<8");
      cwr16(16#680086#, 16#0007#);   fa_chk(16#03CD68#, "16-bit wr@86 0x0007 -> (FA&00FFFF)|Val<<15");
      -- boot sequence regression (single-byte values 40/36/03 -> 0x1B680, verified vs trace)
      cwr(16#680082#, 16#40#); cwr(16#680084#, 16#36#); cwr(16#680086#, 16#03#);
      fa_chk(16#01B680#, "boot FA sequence 40/36/03 -> 0x1B680");

      step("PHASE 6: EXP1 reconfigured to 16-BIT width (the game's 0x173F47 security-era config)");
      ex1_memctrl_s <= MEMCTRL_EXP1_W16;
      tick(4);
      -- the security check itself: lhu of EEPROM word2 (fn_8002C4D8: lhu 0x80(0x1F180000+idx*2))
      crd16_chk(16#180084#, 16#6655#, "SECURITY lhu EEPROM word2 under 16-bit width");
      crd16_chk(16#180080#, 16#2211#, "lhu EEPROM word0 under 16-bit width");
      crd_chk(16#180082#, 16#33#, "byte rd under 16-bit width");
      cwr(16#10#, 16#77#); crd_chk(16#10#, 16#77#, "SCSI CTRL1 echo under 16-bit width");
      ex1_memctrl_s <= MEMCTRL_EXP1;
      tick(4);

      step("SUMMARY");
      write(l, string'("  checks=")); write(l, integer'image(nchk));
      write(l, string'("  failures=")); write(l, integer'image(nfail)); writeline(output, l);
      if nfail = 0 then
         write(l, string'("  RESULT: EXP1 DELIVERY THROUGH REAL memorymux WORKS -- bug is NOT in the EXP1 read/write path."));
      else
         write(l, string'("  RESULT: DELIVERY BUG FOUND through real memorymux -- see **FAIL** lines."));
      end if;
      writeline(output, l);

      tick(10); sim_done <= '1'; wait for 50 ns; finish;
   end process;
end architecture;
