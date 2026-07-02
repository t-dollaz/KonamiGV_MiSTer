library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use std.textio.all;

-- FLASH PREFETCH TIMING TEST. Drives real 16-bit flash reads through the REAL memorymux +
-- konami573 (authentic EXP1 wait-state timing), feeds flash_data from the REAL psx_top memFlash
-- DDR3 FSM (copied verbatim), backed by a DDR3/arbiter model with a tunable latency. The DDR3
-- returns the WORD ADDRESS as data, so a stale read is obvious: a read of FA must return FA(15:0);
-- if it returns FA-1, the prefetch failed to hide the latency. Sweep DDR3_LAT to find the threshold.

entity tb_flash is
   generic (
      DDR3_LAT : integer := 30;   -- clk2x cycles from arbiter-grant to DOUT_READY (DDR3 read latency)
      ARB_LAT  : integer := 4     -- clk2x cycles from request to grant (arbiter)
   );
end entity;

architecture sim of tb_flash is
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

   -- EXP1 wires
   signal bus_exp1_addr      : unsigned(22 downto 0);
   signal bus_exp1_dataWrite : std_logic_vector(7 downto 0);
   signal bus_exp1_read      : std_logic;
   signal bus_exp1_write     : std_logic;
   signal bus_exp1_dataRead  : std_logic_vector(7 downto 0);

   -- konami573 misc
   signal irq10_set        : std_logic;
   signal DMA_EXP_read     : std_logic_vector(31 downto 0);
   signal exp_dmaRequest   : std_logic;
   signal exp_dmaDataValid : std_logic;
   signal disc_req         : std_logic;
   signal disc_lba         : std_logic_vector(31 downto 0);
   signal eeprom_rd, eeprom_wr : std_logic;
   signal eeprom_dataOut   : std_logic_vector(15 downto 0);

   -- flash path (konami573 <-> memFlash FSM)
   signal flash_word_addr  : std_logic_vector(23 downto 0);
   signal flash_fetch      : std_logic;
   signal flash_data       : std_logic_vector(15 downto 0) := (others => '0');
   signal flash_data_ready : std_logic := '0';
   signal flash_rdaddr     : std_logic_vector(23 downto 0) := (others => '1');
   signal bus_exp1_wait_s  : std_logic;

   -- ===== copied verbatim from psx_top.vhd memFlash FSM =====
   signal memFlash_request : std_logic := '0';
   signal memFlash_ack     : std_logic := '0';
   signal memFlash_BE      : std_logic_vector(7 downto 0) := (others => '0');
   signal memFlash_ADDR    : std_logic_vector(23 downto 0) := (others => '0');
   signal memFlash_DIN     : std_logic_vector(63 downto 0) := (others => '0');
   signal memFlash_WE      : std_logic := '0';
   signal memFlash_RD      : std_logic := '0';
   type tFlashState is (FL_IDLE, FL_REQ, FL_RDWAIT, FL_DLWAIT);
   signal flashState       : tFlashState := FL_IDLE;
   signal fl_isWrite       : std_logic := '0';
   signal fl_lane          : unsigned(1 downto 0) := "00";
   signal flash_fetch_q    : std_logic := '0';
   signal reset_intern     : std_logic;
   signal flash_dl_req     : std_logic := '0';
   signal flash_dl_addr    : std_logic_vector(23 downto 0) := (others => '0');
   signal flash_dl_data    : std_logic_vector(15 downto 0) := (others => '0');
   signal flash_dl_done    : std_logic := '0';
   -- DDR3 model side
   signal ddr3_DOUT_READY  : std_logic := '0';
   signal ddr3_DOUT        : std_logic_vector(63 downto 0) := (others => '0');

   -- tie-offs
   signal z32 : std_logic_vector(31 downto 0) := (others => '0');
   signal z16 : std_logic_vector(15 downto 0) := (others => '0');
   signal z8  : std_logic_vector(7 downto 0)  := (others => '0');
   constant MEMCTRL_EXP1 : unsigned(13 downto 0) := to_unsigned(16#263F#, 14);
   constant COMD : unsigned(3 downto 0) := to_unsigned(1, 4);

begin
   clk1x <= not clk1x after 5 ns when sim_done = '0' else '0';
   clk2x <= not clk2x after 2500 ps when sim_done = '0' else '0';
   ce    <= '1';
   reset_intern <= reset;

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
         irq10_set => irq10_set,
         DMA_EXP_read => DMA_EXP_read, DMA_EXP_readEna => '0',
         exp_dmaRequest => exp_dmaRequest, exp_dmaDataValid => exp_dmaDataValid, dma5_done => '0',
         disc_req => disc_req, disc_lba => disc_lba, disc_ack => '0',
         disc_wr => '0', disc_addr => (others=>'0'), disc_data => (others=>'0'), disc_mounted => '1',
         flash_word_addr => flash_word_addr, flash_fetch => flash_fetch,
         flash_data => flash_data, flash_data_ready => flash_data_ready,
         flash_rdaddr => flash_rdaddr, bus_exp1_wait => bus_exp1_wait_s,
         eeprom_load => '0', eeprom_save => '0', eeprom_mounted => '0',
         eeprom_rd => eeprom_rd, eeprom_wr => eeprom_wr, eeprom_ack => '0',
         eeprom_write => '0', eeprom_addr => (others=>'0'), eeprom_dataIn => (others=>'0'),
         eeprom_dataOut => eeprom_dataOut,
         buttons => (others=>'0'), mouse_event => '0', mouse_x => (others=>'0'), mouse_y => (others=>'0')
      );

   -- ===== psx_top memFlash DDR3 FSM, copied verbatim =====
   memflash_fsm : process (clk2x)
   begin
      if rising_edge(clk2x) then
         flash_data_ready <= '0';
         flash_fetch_q    <= flash_fetch;
         if (reset_intern = '1') then
            flashState       <= FL_IDLE;
            memFlash_request <= '0';
            memFlash_RD      <= '0';
            memFlash_WE      <= '0';
            flash_dl_done    <= '0';
            flash_rdaddr     <= (others => '1');
         else
            case flashState is
               when FL_IDLE =>
                  if (flash_dl_req = '1') then
                     fl_isWrite       <= '1';
                     memFlash_ADDR    <= flash_dl_addr;
                     memFlash_DIN     <= flash_dl_data & flash_dl_data & flash_dl_data & flash_dl_data;
                     case flash_dl_addr(2 downto 1) is
                        when "00"   => memFlash_BE <= "00000011";
                        when "01"   => memFlash_BE <= "00001100";
                        when "10"   => memFlash_BE <= "00110000";
                        when others => memFlash_BE <= "11000000";
                     end case;
                     memFlash_WE      <= '1';
                     memFlash_RD      <= '0';
                     memFlash_request <= '1';
                     flashState       <= FL_REQ;
                  elsif (flash_fetch = '1' and flash_fetch_q = '0') then
                     fl_isWrite       <= '0';
                     memFlash_ADDR    <= flash_word_addr(22 downto 0) & '0';
                     fl_lane          <= unsigned(flash_word_addr(1 downto 0));
                     memFlash_BE      <= (others => '1');
                     memFlash_WE      <= '0';
                     memFlash_RD      <= '1';
                     memFlash_request <= '1';
                     flashState       <= FL_REQ;
                  end if;
               when FL_REQ =>
                  if (memFlash_ack = '1') then
                     memFlash_RD      <= '0';
                     memFlash_WE      <= '0';
                     if (fl_isWrite = '1') then
                        memFlash_request <= '0';
                        flash_dl_done <= '1';
                        flashState    <= FL_DLWAIT;
                     else
                        -- READ: hold request through FL_RDWAIT (keeps arbiter vram_pause asserted
                        -- until our DOUT_READY beat lands; matches spu_ram.vhd read contract)
                        flashState    <= FL_RDWAIT;
                     end if;
                  end if;
               when FL_DLWAIT =>
                  if (flash_dl_req = '0') then
                     flash_dl_done <= '0';
                     flashState    <= FL_IDLE;
                  end if;
               when FL_RDWAIT =>
                  assert memFlash_request = '1'
                     report "memFlash_request released before read data returned (vram_pause window broken)"
                     severity failure;
                  if (ddr3_DOUT_READY = '1') then
                     memFlash_request <= '0';   -- our beat landed; release arbiter/vram_pause now
                     case fl_lane is
                        when "00"   => flash_data <= ddr3_DOUT(15 downto 0);
                        when "01"   => flash_data <= ddr3_DOUT(31 downto 16);
                        when "10"   => flash_data <= ddr3_DOUT(47 downto 32);
                        when others => flash_data <= ddr3_DOUT(63 downto 48);
                     end case;
                     flash_rdaddr     <= '0' & memFlash_ADDR(23 downto 1);
                     flash_data_ready <= '1';
                     flashState       <= FL_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   -- ===== DDR3 + arbiter model: grant after ARB_LAT, DOUT after DDR3_LAT, data == word address =====
   ddr3_model : process (clk2x)
      variable ack_cnt : integer := -1;
      variable rd_cnt  : integer := -1;
      variable w       : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk2x) then
         memFlash_ack    <= '0';
         ddr3_DOUT_READY <= '0';
         -- arbiter grant
         if (memFlash_request = '1' and ack_cnt < 0 and flashState = FL_REQ) then
            ack_cnt := ARB_LAT;
         elsif (ack_cnt > 0) then
            ack_cnt := ack_cnt - 1;
         elsif (ack_cnt = 0) then
            memFlash_ack <= '1';
            ack_cnt := -1;
            if (fl_isWrite = '0') then rd_cnt := DDR3_LAT; end if;
         end if;
         -- DDR3 read return: data = word address (memFlash_ADDR is byte addr = word<<1)
         if (rd_cnt > 0) then
            rd_cnt := rd_cnt - 1;
         elsif (rd_cnt = 0) then
            w := memFlash_ADDR(16 downto 1);
            ddr3_DOUT       <= w & w & w & w;
            ddr3_DOUT_READY <= '1';
            rd_cnt := -1;
         end if;
      end if;
   end process;

   stim : process
      variable nfail, nchk : integer := 0;
      variable l : line;
      variable r : std_logic_vector(15 downto 0);
      variable expFA : integer;
      variable exp16 : std_logic_vector(15 downto 0);

      procedure tick(n : integer) is begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      -- CPU byte WRITE to a full EXP1 address
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

      -- CPU 16-bit (halfword) READ of the flash data port; returns the word
      procedure rd16(addr : unsigned(31 downto 0); result : out std_logic_vector(15 downto 0)) is
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= addr;
         mem_in_reqsize     <= "01";        -- halfword
         mem_in_rnw         <= '1'; mem_in_isData <= '1'; mem_in_request <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x); mem_in_request <= '0';
         result := (others => 'U');
         for i in 0 to 200 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then result := mem_dataRead(15 downto 0); exit; end if;
         end loop;
      end procedure;
   begin
      write(l, string'("=== FLASH PREFETCH TEST  DDR3_LAT=")); write(l, integer'image(DDR3_LAT));
      write(l, string'(" clk2x  ARB_LAT=")); write(l, integer'image(ARB_LAT)); writeline(output, l);

      reset <= '1'; tick(8); wait until falling_edge(clk1x); reset <= '0'; tick(4);

      -- set FlashAddress = 0x1B680 (writes 40/36/03 to offsets 2/4/6), as in the real boot
      bwr(x"1F680082", 16#40#);
      bwr(x"1F680084", 16#36#);
      bwr(x"1F680086", 16#03#);

      -- tight back-to-back 16-bit reads of the flash data port; each must return its own FA(15:0)
      for n in 0 to 31 loop
         rd16(x"1F680080", r);
         nchk := nchk + 1;
         expFA := 16#1B680# + n;
         exp16 := std_logic_vector(to_unsigned(expFA mod 65536, 16));
         if r /= exp16 then
            nfail := nfail + 1;
            write(l, string'("  **STALE** read ")); write(l, integer'image(n));
            write(l, string'(" expFA(15:0)=0x")); hwrite(l, exp16);
            write(l, string'(" got=0x")); hwrite(l, r);
            write(l, string'("  (off by ")); write(l, integer'image(to_integer(unsigned(exp16)) - to_integer(unsigned(r)))); write(l, string'(")"));
            writeline(output, l);
         end if;
      end loop;

      write(l, string'("SUMMARY DDR3_LAT=")); write(l, integer'image(DDR3_LAT));
      write(l, string'("  reads=")); write(l, integer'image(nchk));
      write(l, string'("  stale=")); write(l, integer'image(nfail));
      writeline(output, l);
      if nfail = 0 then
         write(l, string'("  RESULT: all reads correct -- prefetch HIDES the latency at this DDR3_LAT"));
      else
         write(l, string'("  RESULT: STALE reads -- prefetch FAILS to hide the latency -> corrupted flash data"));
      end if;
      writeline(output, l);

      tick(10); sim_done <= '1'; wait for 50 ns; finish;
   end process;
end architecture;
