library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use std.textio.all;

-- 29F016A WRITE-PATH TEST (docs/FLASH_WRITE_DESIGN.md). Drives the AMD command sequences the
-- game's TEST mode needs through the REAL memorymux + konami573, against the REAL psx_top
-- memFlash FSM (copied verbatim, incl. the new op states), backed by an ARRAY-model DDR3 so
-- programs/erases are observable. Scenarios: read regression, ID autoselect, byte program
-- (AND semantics), 64KB sector erase with DQ7/DQ6 status polling, per-lane isolation.
-- Init pattern: word[i] = i(15:0), except scratch window 0x1000-0x10FF = 0xFFFF (erased state).

entity tb_flash_write is
   generic (
      DDR3_LAT : integer := 20;
      ARB_LAT  : integer := 4
   );
end entity;

architecture sim of tb_flash_write is
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
   signal bus_exp1_bstep     : std_logic_vector(1 downto 0);

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
   signal flash_op_req     : std_logic;
   signal flash_op_fill    : std_logic;
   signal flash_op_addr    : std_logic_vector(23 downto 0);
   signal flash_op_len     : unsigned(21 downto 0);
   signal flash_op_data    : std_logic_vector(7 downto 0);
   signal flash_op_lane    : std_logic;
   signal flash_op_done    : std_logic := '0';

   -- ===== copied verbatim from psx_top.vhd memFlash FSM (with 29F016A op states) =====
   signal memFlash_request : std_logic := '0';
   signal memFlash_ack     : std_logic := '0';
   signal memFlash_BE      : std_logic_vector(7 downto 0) := (others => '0');
   signal memFlash_ADDR    : std_logic_vector(23 downto 0) := (others => '0');
   signal memFlash_DIN     : std_logic_vector(63 downto 0) := (others => '0');
   signal memFlash_WE      : std_logic := '0';
   signal memFlash_RD      : std_logic := '0';
   type tFlashState is (FL_IDLE, FL_REQ, FL_RDWAIT, FL_DLWAIT,
                        FL_OPREAD, FL_OPMOD, FL_OPWRITE, FL_FILL, FL_FILLNEXT, FL_OPACK);
   signal flashState       : tFlashState := FL_IDLE;
   signal fl_isWrite       : std_logic := '0';
   signal fl_lane          : unsigned(1 downto 0) := "00";
   signal flash_fetch_q    : std_logic := '0';
   signal reset_intern     : std_logic;
   signal flash_dl_req     : std_logic := '0';
   signal flash_dl_addr    : std_logic_vector(23 downto 0) := (others => '0');
   signal flash_dl_data    : std_logic_vector(15 downto 0) := (others => '0');
   signal flash_dl_done    : std_logic := '0';
   signal fl_op_cnt        : unsigned(19 downto 0) := (others => '0');
   signal fl_op_line       : std_logic_vector(63 downto 0) := (others => '0');
   -- DDR3 model side
   signal ddr3_DOUT_READY  : std_logic := '0';
   signal ddr3_DOUT        : std_logic_vector(63 downto 0) := (others => '0');

   -- array-backed DDR3 model: 4M x 16-bit = the full interleaved 8MB flash space
   type t_fmem is array(0 to 4*1024*1024-1) of std_logic_vector(15 downto 0);
   impure function init_mem return t_fmem is
      variable m : t_fmem;
   begin
      for i in m'range loop
         m(i) := std_logic_vector(to_unsigned(i mod 65536, 16));
      end loop;
      for i in 16#1000# to 16#10FF# loop        -- pre-erased scratch window for program tests
         m(i) := x"FFFF";
      end loop;
      return m;
   end function;
   shared variable flashmem : t_fmem := init_mem;

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
         bus_exp1_bstep => bus_exp1_bstep,
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
         irq10_set => irq10_set,
         DMA_EXP_read => DMA_EXP_read, DMA_EXP_readEna => '0',
         exp_dmaRequest => exp_dmaRequest, exp_dmaDataValid => exp_dmaDataValid, dma5_done => '0',
         disc_req => disc_req, disc_lba => disc_lba, disc_ack => '0',
         disc_wr => '0', disc_addr => (others=>'0'), disc_data => (others=>'0'), disc_mounted => '1',
         flash_word_addr => flash_word_addr, flash_fetch => flash_fetch,
         flash_data => flash_data, flash_data_ready => flash_data_ready,
         flash_rdaddr => flash_rdaddr, bus_exp1_wait => bus_exp1_wait_s,
         flash_op_req => flash_op_req, flash_op_fill => flash_op_fill,
         flash_op_addr => flash_op_addr, flash_op_len => flash_op_len,
         flash_op_data => flash_op_data, flash_op_lane => flash_op_lane,
         flash_op_done => flash_op_done,
         eeprom_load => '0', eeprom_save => '0', eeprom_mounted => '0',
         eeprom_rd => eeprom_rd, eeprom_wr => eeprom_wr, eeprom_ack => '0',
         eeprom_write => '0', eeprom_addr => (others=>'0'), eeprom_dataIn => (others=>'0'),
         eeprom_dataOut => eeprom_dataOut,
         buttons => (others=>'0'), mouse_event => '0', mouse_x => (others=>'0'), mouse_y => (others=>'0')
      );

   -- ===== psx_top memFlash DDR3 FSM, copied verbatim (incl. 29F016A op states) =====
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
            flash_op_done    <= '0';
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
                  elsif (flash_op_req = '1' and flash_op_done = '0') then
                     if (flash_op_fill = '1') then
                        memFlash_ADDR    <= flash_op_addr(22 downto 0) & '0';
                        memFlash_DIN     <= (others => '1');
                        if (flash_op_lane = '0') then
                           memFlash_BE   <= "01010101";
                        else
                           memFlash_BE   <= "10101010";
                        end if;
                        memFlash_WE      <= '1';
                        memFlash_RD      <= '0';
                        memFlash_request <= '1';
                        fl_op_cnt        <= resize(flash_op_len(21 downto 2), 20) - 1;
                        flashState       <= FL_FILL;
                        report "DBG FSM: fill start addr=" & to_hstring(flash_op_addr) & " len=" & to_hstring(std_logic_vector(flash_op_len)) severity note;
                     else
                        memFlash_ADDR    <= flash_op_addr(22 downto 0) & '0';
                        fl_lane          <= unsigned(flash_op_addr(1 downto 0));
                        memFlash_BE      <= (others => '1');
                        memFlash_WE      <= '0';
                        memFlash_RD      <= '1';
                        memFlash_request <= '1';
                        flashState       <= FL_OPREAD;
                     end if;
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
                     report "memFlash_request released before read data returned"
                     severity failure;
                  if (ddr3_DOUT_READY = '1') then
                     memFlash_request <= '0';
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

               when FL_OPREAD =>
                  if (memFlash_ack = '1') then
                     memFlash_RD <= '0';
                  end if;
                  if (ddr3_DOUT_READY = '1') then
                     memFlash_request <= '0';
                     fl_op_line       <= ddr3_DOUT;
                     flashState       <= FL_OPMOD;
                  end if;

               when FL_OPMOD =>
                  for i in 0 to 7 loop
                     if (flash_op_lane = '0' and i = to_integer(fl_lane) * 2) or
                        (flash_op_lane = '1' and i = to_integer(fl_lane) * 2 + 1) then
                        memFlash_DIN(i*8+7 downto i*8) <= fl_op_line(i*8+7 downto i*8) and flash_op_data;
                        memFlash_BE(i)                 <= '1';
                     else
                        memFlash_DIN(i*8+7 downto i*8) <= fl_op_line(i*8+7 downto i*8);
                        memFlash_BE(i)                 <= '0';
                     end if;
                  end loop;
                  memFlash_WE      <= '1';
                  memFlash_request <= '1';
                  flashState       <= FL_OPWRITE;

               when FL_OPWRITE =>
                  if (memFlash_ack = '1') then
                     memFlash_WE      <= '0';
                     memFlash_request <= '0';
                     flash_rdaddr     <= (others => '1');
                     flash_op_done    <= '1';
                     flashState       <= FL_OPACK;
                  end if;

               when FL_FILL =>
                  if (memFlash_ack = '1') then
                     memFlash_WE      <= '0';
                     memFlash_request <= '0';
                     if (fl_op_cnt = 0) then
                        flash_rdaddr  <= (others => '1');
                        flash_op_done <= '1';
                        flashState    <= FL_OPACK;
                        report "DBG FSM: fill complete" severity note;
                     else
                        fl_op_cnt     <= fl_op_cnt - 1;
                        flashState    <= FL_FILLNEXT;
                     end if;
                  end if;

               when FL_FILLNEXT =>
                  memFlash_ADDR    <= std_logic_vector(unsigned(memFlash_ADDR) + 8);
                  memFlash_WE      <= '1';
                  memFlash_request <= '1';
                  flashState       <= FL_FILL;

               when FL_OPACK =>
                  if (flash_op_req = '0') then
                     flash_op_done <= '0';
                     flashState    <= FL_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   -- ===== DDR3 + arbiter model, array-backed. Grant ARB_LAT after a request with RD/WE
   -- still up (RD/WE clear on ack in every FSM path, so no double grants); writes apply
   -- at grant time with BE; reads return the 4-word line after DDR3_LAT. =====
   ddr3_model : process (clk2x)
      variable ack_cnt : integer := -1;
      variable rd_cnt  : integer := -1;
      variable base    : integer;
   begin
      if rising_edge(clk2x) then
         memFlash_ack    <= '0';
         ddr3_DOUT_READY <= '0';
         if (memFlash_request = '1' and ack_cnt < 0 and rd_cnt < 0 and (memFlash_RD = '1' or memFlash_WE = '1')) then
            ack_cnt := ARB_LAT;
         elsif (ack_cnt > 0) then
            ack_cnt := ack_cnt - 1;
         elsif (ack_cnt = 0) then
            memFlash_ack <= '1';
            ack_cnt := -1;
            base := to_integer(unsigned(memFlash_ADDR(23 downto 3))) * 4;   -- line base word
            if (memFlash_WE = '1') then
               for i in 0 to 7 loop
                  if memFlash_BE(i) = '1' then
                     if (i mod 2) = 0 then
                        flashmem(base + i/2)(7 downto 0)  := memFlash_DIN(i*8+7 downto i*8);
                     else
                        flashmem(base + i/2)(15 downto 8) := memFlash_DIN(i*8+7 downto i*8);
                     end if;
                  end if;
               end loop;
            else
               rd_cnt := DDR3_LAT;
            end if;
         end if;
         if (rd_cnt > 0) then
            rd_cnt := rd_cnt - 1;
         elsif (rd_cnt = 0) then
            base := to_integer(unsigned(memFlash_ADDR(23 downto 3))) * 4;
            ddr3_DOUT <= flashmem(base+3) & flashmem(base+2) & flashmem(base+1) & flashmem(base+0);
            ddr3_DOUT_READY <= '1';
            rd_cnt := -1;
         end if;
      end if;
   end process;

   stim : process
      variable nfail, nchk : integer := 0;
      variable l : line;
      variable r : std_logic_vector(15 downto 0);
      variable exp16 : std_logic_vector(15 downto 0);
      variable polls : integer;

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

      -- 16-bit write to an even EXP1 address (both byte lanes -> both chip FSMs)
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

      -- set FlashAddress via the address regs (write order matters: reg2 RESETS FA).
      -- Handles even FAs up to 22 bits; for odd FAs, sets FA-1 then FA|=1 via the
      -- offset-8 read (the same mechanism the game uses - konamigv.cpp flash_r case 8).
      procedure setFA(fa : integer) is
         variable f : unsigned(23 downto 0) := to_unsigned(fa, 24);
         variable dummy : std_logic_vector(15 downto 0);
      begin
         -- konami.cpp write semantics: @2 FA=v<<1 (resets); @4 FA=(FA&0xFF00FF)|v<<8
         -- (overwrites 15:8, clears nothing else it kept); @6 FA=(FA&0x00FFFF)|v<<15 (ORs
         -- into 22:15). Put bit 15 in the reg-4 byte and keep the reg-6 value even so the
         -- OR never double-drives it. Odd addresses use the offset-8 read (FA|=1), the
         -- same mechanism the game uses (konamigv.cpp flash_r case 8).
         bwr(x"1F680082", to_integer('0' & f(7 downto 1)));
         bwr(x"1F680084", to_integer(f(15 downto 8)));
         bwr(x"1F680086", to_integer(f(22 downto 16) & '0'));
         if f(0) = '1' then
            rd16(x"1F680088", dummy);   -- offset 8: FA |= 1
         end if;
      end procedure;

      procedure chk(name : string; got : std_logic_vector(15 downto 0); exp : std_logic_vector(15 downto 0)) is
      begin
         nchk := nchk + 1;
         if got /= exp then
            nfail := nfail + 1;
            write(l, string'("  **FAIL** ") & name & string'("  exp=0x")); hwrite(l, exp);
            write(l, string'(" got=0x")); hwrite(l, got); writeline(output, l);
         end if;
      end procedure;
   begin
      write(l, string'("=== 29F016A WRITE-PATH TEST  DDR3_LAT=")); write(l, integer'image(DDR3_LAT));
      writeline(output, l);

      reset <= '1'; tick(8); wait until falling_edge(clk1x); reset <= '0'; tick(4);

      ------------------------------------------------------------------
      -- 1. read regression: FA=0x1B680, 8 tight reads must be exact
      ------------------------------------------------------------------
      bwr(x"1F680082", 16#40#); bwr(x"1F680084", 16#36#); bwr(x"1F680086", 16#03#);
      for n in 0 to 7 loop
         rd16(x"1F680080", r);
         chk("regression read " & integer'image(n), r, std_logic_vector(to_unsigned((16#1B680# + n) mod 65536, 16)));
      end loop;

      ------------------------------------------------------------------
      -- 2. ID autoselect: AA@555 / 55@2AA / 90@555 -> 0x0404, 0xADAD; F0 resets
      ------------------------------------------------------------------
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#555#); wr16(x"1F680080", 16#9090#);
      setFA(0);
      rd16(x"1F680080", r); chk("ID maker", r, x"0404");
      rd16(x"1F680080", r); chk("ID device", r, x"ADAD");   -- FA auto-incremented to 1
      rd16(x"1F680080", r); chk("ID undefined", r, x"0000");
      wr16(x"1F680080", 16#F0F0#);                           -- reset to array mode
      setFA(5);
      rd16(x"1F680080", r); chk("array after F0 reset", r, x"0005");

      ------------------------------------------------------------------
      -- 3. byte program: AA/55/A0 then data; AND semantics on reprogram
      ------------------------------------------------------------------
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#555#); wr16(x"1F680080", 16#A0A0#);
      setFA(16#1000#); wr16(x"1F680080", 16#1234#);          -- program over 0xFFFF scratch
      setFA(16#1000#);
      rd16(x"1F680080", r); chk("program 0x1234 over 0xFFFF", r, x"1234");
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#555#); wr16(x"1F680080", 16#A0A0#);
      setFA(16#1000#); wr16(x"1F680080", 16#00FF#);          -- reprogram: 0x1234 AND 0x00FF
      setFA(16#1000#);
      rd16(x"1F680080", r); chk("program AND semantics", r, x"0034");

      ------------------------------------------------------------------
      -- 4. lane isolation: lo-chip-only program via byte writes
      ------------------------------------------------------------------
      setFA(16#555#); bwr(x"1F680080", 16#AA#);
      setFA(16#2AA#); bwr(x"1F680080", 16#55#);
      setFA(16#555#); bwr(x"1F680080", 16#A0#);
      setFA(16#1010#); bwr(x"1F680080", 16#00#);             -- lo byte of 0xFFFF -> 0x00
      setFA(16#1010#);
      rd16(x"1F680080", r); chk("lo-lane-only program", r, x"FF00");

      ------------------------------------------------------------------
      -- 5. 64KB sector erase (sector 0 = words 0x0000-0xFFFF), DQ7/DQ6 polling
      ------------------------------------------------------------------
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#555#); wr16(x"1F680080", 16#8080#);
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#4000#); wr16(x"1F680080", 16#3030#);          -- sector erase @word 0x4000 (in sector 0)
      -- immediately: status reads (DQ7=0); poll until DQ7=1 (array 0xFF visible)
      setFA(16#4000#);
      rd16(x"1F680080", r);
      nchk := nchk + 1;
      if r(7) = '1' or r(15) = '1' then
         nfail := nfail + 1;
         write(l, string'("  **FAIL** erase status DQ7 not busy right after command, got=0x")); hwrite(l, r); writeline(output, l);
      end if;
      polls := 0;
      loop
         setFA(16#4000#);
         rd16(x"1F680080", r);
         exit when r(7) = '1' and r(15) = '1';               -- DQ7=1 on both chips = done (array 0xFF)
         polls := polls + 1;
         assert polls < 100000 report "sector erase never completed" severity failure;
      end loop;
      write(l, string'("  sector erase completed after ")); write(l, integer'image(polls));
      write(l, string'(" polls")); writeline(output, l);
      setFA(16#0000#); rd16(x"1F680080", r); chk("erased word 0x0000", r, x"FFFF");
      setFA(16#8000#); rd16(x"1F680080", r); chk("erased word 0x8000", r, x"FFFF");
      setFA(16#FFFE#); rd16(x"1F680080", r); chk("erased word 0xFFFE", r, x"FFFF");
      setFA(16#10000#); rd16(x"1F680080", r); chk("word outside sector untouched", r, x"0000");
      setFA(16#10400#); rd16(x"1F680080", r); chk("word outside sector untouched 2", r, x"0400");
      -- direct array bounds check (no EXP1 round-trips): full sector, both lanes
      nchk := nchk + 1;
      for i in 0 to 16#FFFF# loop
         if flashmem(i) /= x"FFFF" then
            nfail := nfail + 1;
            write(l, string'("  **FAIL** sector word not erased at 0x"));
            hwrite(l, std_logic_vector(to_unsigned(i, 24))); writeline(output, l);
            exit;
         end if;
      end loop;

      ------------------------------------------------------------------
      -- 6. FOUR-CHIP ISOLATION (the bulk-init killer): pair is FA bit 21
      --    (konamigv.cpp:704). Put pair1-lo (chip 7A) in ID mode; pair0-lo (3A)
      --    reads must still return ARRAY data, and vice versa on reset.
      ------------------------------------------------------------------
      setFA(16#200555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2002AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#200555#); wr16(x"1F680080", 16#9090#);   -- pair1 chips -> ID mode
      setFA(16#200000#);
      rd16(x"1F680080", r); chk("pair1 ID mode", r, x"0404");
      setFA(16#10400#);                                  -- pair0 address
      rd16(x"1F680080", r); chk("pair0 array while pair1 in ID", r, x"0400");
      setFA(16#200000#); wr16(x"1F680080", 16#F0F0#);    -- reset pair1
      setFA(16#200000#);
      rd16(x"1F680080", r); chk("pair1 array after reset", r, x"0000");

      -- pair0 sector erase must NOT put pair1 into status mode after completion
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#555#); wr16(x"1F680080", 16#8080#);
      setFA(16#555#); wr16(x"1F680080", 16#AAAA#);
      setFA(16#2AA#); wr16(x"1F680080", 16#5555#);
      setFA(16#14000#); wr16(x"1F680080", 16#3030#);     -- erase pair0 sector @0x14000
      polls := 0;
      loop
         setFA(16#14000#);
         rd16(x"1F680080", r);
         exit when r(7) = '1' and r(15) = '1';
         polls := polls + 1;
         assert polls < 100000 report "pair0 sector erase never completed" severity failure;
      end loop;
      setFA(16#14000#); rd16(x"1F680080", r); chk("pair0 sector erased", r, x"FFFF");
      setFA(16#200100#); rd16(x"1F680080", r); chk("pair1 array after pair0 erase", r, x"0100");
      setFA(16#0100#);   rd16(x"1F680080", r); chk("pair0 outside sector intact", r, x"FFFF");
      -- ^ 0x0100 is inside sector 0 which scenario 5 erased -> 0xFFFF expected

      ------------------------------------------------------------------
      write(l, string'("SUMMARY checks=")); write(l, integer'image(nchk));
      write(l, string'(" fails=")); write(l, integer'image(nfail)); writeline(output, l);
      if nfail = 0 then
         write(l, string'("ALL PASS")); writeline(output, l);
      else
         write(l, string'("FAILURES PRESENT")); writeline(output, l);
      end if;
      tick(10); sim_done <= '1'; wait for 50 ns; finish;
   end process;
end architecture;
