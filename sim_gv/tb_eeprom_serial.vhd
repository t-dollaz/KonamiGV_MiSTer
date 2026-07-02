library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use std.textio.all;

-- 93C46 SERIAL EEPROM TEST. Bit-bangs the MAME-documented GV wiring through the REAL
-- memorymux + konami573: writes to 0x1F180000 (bit0=DI, bit1=CS, bit2=CLK per
-- konamigv.cpp:406/667-670), DO read back through P1 bit 0x2000 (konamigv.cpp:624).
-- Scenarios: EWEN, WRITE + window-coherence, serial READ, window-write -> serial-read
-- coherence, ERASE, EWDS lock, serial-port/window aliasing fix.

entity tb_eeprom_serial is
end entity;

architecture sim of tb_eeprom_serial is
   signal clk1x, clk2x, ce, reset : std_logic := '0';
   signal sim_done : std_logic := '0';

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

   signal bus_exp1_addr      : unsigned(22 downto 0);
   signal bus_exp1_dataWrite : std_logic_vector(7 downto 0);
   signal bus_exp1_read      : std_logic;
   signal bus_exp1_write     : std_logic;
   signal bus_exp1_dataRead  : std_logic_vector(7 downto 0);
   signal bus_exp1_bstep     : std_logic_vector(1 downto 0);
   signal bus_exp1_a10       : std_logic_vector(1 downto 0);
   signal bus_exp1_wait_s    : std_logic;

   signal irq10_set        : std_logic;
   signal DMA_EXP_read     : std_logic_vector(31 downto 0);
   signal exp_dmaRequest   : std_logic;
   signal exp_dmaDataValid : std_logic;
   signal disc_req         : std_logic;
   signal disc_lba         : std_logic_vector(31 downto 0);
   signal eeprom_rd, eeprom_wr : std_logic;
   signal eeprom_dataOut   : std_logic_vector(15 downto 0);
   signal flash_word_addr  : std_logic_vector(23 downto 0);
   signal flash_fetch      : std_logic;

   signal z32 : std_logic_vector(31 downto 0) := (others => '0');
   signal z16 : std_logic_vector(15 downto 0) := (others => '0');
   signal z8  : std_logic_vector(7 downto 0)  := (others => '0');
   constant MEMCTRL_EXP1 : unsigned(13 downto 0) := to_unsigned(16#263F#, 14);
   constant COMD : unsigned(3 downto 0) := to_unsigned(1, 4);

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
         bios_memctrl => MEMCTRL_EXP1, ex1_memctrl => MEMCTRL_EXP1,
         bus_exp1_addr => bus_exp1_addr, bus_exp1_dataWrite => bus_exp1_dataWrite,
         bus_exp1_read => bus_exp1_read, bus_exp1_write => bus_exp1_write, bus_exp1_dataRead => bus_exp1_dataRead,
         bus_exp1_bstep => bus_exp1_bstep,
         bus_exp1_a10 => bus_exp1_a10,
         bus_exp1_wait => bus_exp1_wait_s,
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
         bus_bstep => bus_exp1_bstep,
         bus_a10 => bus_exp1_a10,
         irq10_set => irq10_set,
         DMA_EXP_read => DMA_EXP_read, DMA_EXP_readEna => '0',
         exp_dmaRequest => exp_dmaRequest, exp_dmaDataValid => exp_dmaDataValid, dma5_done => '0',
         disc_req => disc_req, disc_lba => disc_lba, disc_ack => '0',
         disc_wr => '0', disc_addr => (others=>'0'), disc_data => (others=>'0'), disc_mounted => '1',
         flash_word_addr => flash_word_addr, flash_fetch => flash_fetch,
         flash_data => (others=>'0'), flash_data_ready => '0',
         flash_rdaddr => (others=>'1'), bus_exp1_wait => bus_exp1_wait_s,
         eeprom_load => '0', eeprom_save => '0', eeprom_mounted => '0',
         eeprom_rd => eeprom_rd, eeprom_wr => eeprom_wr, eeprom_ack => '0',
         eeprom_write => '0', eeprom_addr => (others=>'0'), eeprom_dataIn => (others=>'0'),
         eeprom_dataOut => eeprom_dataOut,
         buttons => (others=>'0'), mouse_event => '0', mouse_x => (others=>'0'), mouse_y => (others=>'0')
      );

   stim : process
      variable nfail, nchk : integer := 0;
      variable l : line;
      variable r16 : std_logic_vector(15 downto 0);
      variable rd_word : std_logic_vector(15 downto 0);
      variable dob : std_logic;

      procedure tick(n : integer) is begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      procedure bwr(addr : unsigned(31 downto 0); val : integer) is
         variable lane : integer := to_integer(addr(1 downto 0));
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= addr;
         mem_in_dataWrite   <= std_logic_vector(to_unsigned(val,8)) & std_logic_vector(to_unsigned(val,8)) &
                               std_logic_vector(to_unsigned(val,8)) & std_logic_vector(to_unsigned(val,8));
         mem_in_writeMask   <= std_logic_vector(to_unsigned(2**lane, 4));
         mem_in_reqsize     <= "00";
         mem_in_rnw         <= '0'; mem_in_isData <= '1'; mem_in_request <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x); mem_in_request <= '0';
         for i in 0 to 60 loop wait until rising_edge(clk1x); exit when isIdle = '0'; end loop;
         for i in 0 to 200 loop wait until rising_edge(clk1x); exit when isIdle = '1'; end loop;
      end procedure;

      procedure wr16(addr : unsigned(31 downto 0); val : integer) is
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= addr;
         mem_in_dataWrite   <= x"0000" & std_logic_vector(to_unsigned(val, 16));
         mem_in_writeMask   <= "0011";
         mem_in_reqsize     <= "01";
         mem_in_rnw         <= '0'; mem_in_isData <= '1'; mem_in_request <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x); mem_in_request <= '0';
         for i in 0 to 60 loop wait until rising_edge(clk1x); exit when isIdle = '0'; end loop;
         for i in 0 to 200 loop wait until rising_edge(clk1x); exit when isIdle = '1'; end loop;
      end procedure;

      procedure rd16(addr : unsigned(31 downto 0); result : out std_logic_vector(15 downto 0)) is
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= addr;
         mem_in_reqsize     <= "01";
         mem_in_rnw         <= '1'; mem_in_isData <= '1'; mem_in_request <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x); mem_in_request <= '0';
         result := (others => 'U');
         for i in 0 to 400 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then result := mem_dataRead(15 downto 0); exit; end if;
         end loop;
      end procedure;

      -- serial line helpers (konamigv.cpp EEPROMOUT: bit0=DI, bit1=CS, bit2=CLK)
      procedure ser(di, cs, clkv : integer) is
      begin
         wr16(x"1F180000", di + cs*2 + clkv*4);
      end procedure;

      procedure clock_in(di : integer) is
      begin
         ser(di, 1, 0);
         ser(di, 1, 1);      -- rising CLK samples DI
      end procedure;

      -- DO = P1 bit 13
      procedure read_do(result : out std_logic) is
         variable v : std_logic_vector(15 downto 0);
      begin
         rd16(x"1F100000", v);
         result := v(13);
      end procedure;

      -- start a command: CS low->high, start bit, then 8 command+address bits MSB first
      procedure cmd(op : integer; addr : integer) is
         variable bits : unsigned(7 downto 0);
      begin
         ser(0, 0, 0);
         ser(0, 1, 0);
         clock_in(1);                              -- start bit
         bits := to_unsigned(op*64 + addr, 8);
         for i in 7 downto 0 loop
            clock_in(to_integer(unsigned'("" & bits(i))));
         end loop;
      end procedure;

      procedure data16(v : integer) is
         variable bits : unsigned(15 downto 0) := to_unsigned(v, 16);
      begin
         for i in 15 downto 0 loop
            clock_in(to_integer(unsigned'("" & bits(i))));
         end loop;
      end procedure;

      procedure cs_off is begin ser(0, 0, 0); end procedure;

      -- serial read of a word: cmd READ then 16 clocks collecting DO after each rising edge
      procedure ser_read(addr : integer; result : out std_logic_vector(15 downto 0)) is
         variable acc : std_logic_vector(15 downto 0) := (others => '0');
         variable b : std_logic;
      begin
         cmd(2, addr);                             -- opcode 10 = READ
         for i in 0 to 15 loop
            clock_in(0);
            read_do(b);
            acc := acc(14 downto 0) & b;
         end loop;
         cs_off;
         result := acc;
      end procedure;

      procedure chk16(name : string; got, exp : std_logic_vector(15 downto 0)) is
      begin
         nchk := nchk + 1;
         if got /= exp then
            nfail := nfail + 1;
            write(l, string'("  **FAIL** ") & name & string'(" exp=0x")); hwrite(l, exp);
            write(l, string'(" got=0x")); hwrite(l, got); writeline(output, l);
         end if;
      end procedure;
      procedure chkb(name : string; got, exp : std_logic) is
      begin
         nchk := nchk + 1;
         if got /= exp then
            nfail := nfail + 1;
            write(l, string'("  **FAIL** ") & name & string'(" exp=") & std_logic'image(exp) &
                     string'(" got=") & std_logic'image(got));
            writeline(output, l);
         end if;
      end procedure;
   begin
      write(l, string'("=== 93C46 SERIAL EEPROM TEST ===")); writeline(output, l);
      reset <= '1'; tick(8); wait until falling_edge(clk1x); reset <= '0'; tick(4);

      -- 0. DO idles high (ready) - unchanged normal-boot behavior
      read_do(dob); chkb("DO idle high", dob, '1');

      -- 1. locked by default: WRITE word 5 = 0x1234 must be ignored
      cmd(1, 5); data16(16#1234#); cs_off;
      rd16(x"1F18008A", r16); chk16("locked write ignored (window w5)", r16, x"0000");

      -- 2. EWEN (00 110000), then WRITE word 5 = 0x1234
      cmd(0, 16#30#); cs_off;
      cmd(1, 5); data16(16#1234#); cs_off;
      -- ready poll: CS up, DO should read 1 (instant completion)
      ser(0, 1, 0);
      read_do(dob); chkb("ready after write", dob, '1');
      cs_off;
      rd16(x"1F18008A", r16); chk16("serial write -> window w5", r16, x"1234");
      write(l, string'("  DBG first w5 read: 0x")); hwrite(l, r16); writeline(output, l);
      rd16(x"1F180088", r16);
      write(l, string'("  DBG w4 read: 0x")); hwrite(l, r16); writeline(output, l);
      rd16(x"1F18008A", r16);
      write(l, string'("  DBG second w5 read: 0x")); hwrite(l, r16); writeline(output, l);

      -- 3. serial READ of word 5
      ser_read(5, rd_word); chk16("serial read w5", rd_word, x"1234");

      -- 4. coherence: window write word 8 = 0xBEEF (byte writes), serial read
      bwr(x"1F180090", 16#EF#); bwr(x"1F180091", 16#BE#);
      ser_read(8, rd_word); chk16("window write -> serial read w8", rd_word, x"BEEF");

      -- 5. ERASE word 5 -> 0xFFFF
      cmd(3, 5); cs_off;
      ser_read(5, rd_word); chk16("erase w5", rd_word, x"FFFF");

      -- 6. EWDS locks again
      cmd(0, 16#00#); cs_off;
      cmd(1, 8); data16(16#0BAD#); cs_off;
      ser_read(8, rd_word); chk16("locked write after EWDS", rd_word, x"BEEF");

      -- 7. serial-port writes must NOT alias into window bytes 0-3 (ee_wren fix):
      --    all the bit-banging above wrote 0x1F180000 repeatedly; window byte 0 untouched
      rd16(x"1F180080", r16); chk16("no serial->window aliasing (w0)", r16, x"0000");

      -- 8. window read below 0x80 returns 0 (konami.cpp)
      rd16(x"1F180000", r16); chk16("sub-window read = 0", r16, x"0000");

      write(l, string'("SUMMARY checks=")); write(l, integer'image(nchk));
      write(l, string'(" fails=")); write(l, integer'image(nfail)); writeline(output, l);
      if nfail = 0 then write(l, string'("ALL PASS")); else write(l, string'("FAILURES PRESENT")); end if;
      writeline(output, l);
      tick(10); sim_done <= '1'; wait for 50 ns; finish;
   end process;
end architecture;
