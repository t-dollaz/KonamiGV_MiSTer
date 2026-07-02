-- Positive-control TB for the cycling milestone probe in konami573.vhd.
-- Drives REAL region-0x68 flash (off 0x680080) and trackball (off 0x6800C0) accesses,
-- then watches disc_lba. Expected probe bands (disc_lba = ScsiSectorLba*2):
--   heartbeat ph0 = 0x800 | P1 ph1 = 0x1000 | EEPROM ph2 = 0x1800 | TRACKBALL ph3 = 0x2000
--   FLASH ph4 = 0x2800 | SCSI ph5 = 0x3000 | READ10 ph6 = 0x3800
-- If after a flash read we see disc_lba 0x2800 -> ms_flash latch+fire WORKS.
-- If after a trackball read we see 0x2000 -> ms_tball WORKS.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
entity tb_milestone is end entity;
architecture sim of tb_milestone is
   signal clk1x : std_logic := '0';
   signal ce : std_logic := '1';
   signal reset : std_logic := '1';
   signal bus_addr : unsigned(22 downto 0) := (others => '0');
   signal bus_dataWrite : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';
   signal bus_dataRead : std_logic_vector(7 downto 0);
   signal irq10_set : std_logic;
   signal DMA_EXP_read : std_logic_vector(31 downto 0);
   signal DMA_EXP_readEna : std_logic := '0';
   signal exp_dmaRequest, exp_dmaDataValid : std_logic;
   signal dma5_done : std_logic := '0';
   signal disc_req : std_logic;
   signal disc_lba : std_logic_vector(31 downto 0);
   signal disc_ack : std_logic := '0';
   signal disc_wr : std_logic := '0';
   signal disc_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal disc_data : std_logic_vector(15 downto 0) := (others => '0');
   signal disc_mounted : std_logic := '1';
   signal flash_word_addr : std_logic_vector(23 downto 0);
   signal flash_fetch : std_logic;
   signal flash_data : std_logic_vector(15 downto 0) := (others => '0');
   signal flash_data_ready : std_logic := '0';
   signal eeprom_load, eeprom_save, eeprom_mounted : std_logic := '0';
   signal eeprom_rd, eeprom_wr : std_logic;
   signal eeprom_ack, eeprom_write : std_logic := '0';
   signal eeprom_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal eeprom_dataIn : std_logic_vector(15 downto 0) := (others => '0');
   signal eeprom_dataOut : std_logic_vector(15 downto 0);
   signal buttons : unsigned(31 downto 0) := (others => '0');
   signal mouse_event : std_logic := '0';
   signal mouse_x, mouse_y : signed(8 downto 0) := (others => '0');
   signal cpu_pc_tb : unsigned(31 downto 0) := x"800200E8";  -- known PC to recover
   signal sim_done : std_logic := '0';
begin
   clk1x <= not clk1x after 5 ns when sim_done = '0' else '0';
   dut : entity work.konami573
      generic map ( DBG_PC_CNT_BITS => 6 )
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
   -- disc HPS responder (ack + stream 512 words)
   disc_hps : process begin
      disc_ack <= '0'; disc_wr <= '0'; disc_addr <= (others=>'0'); disc_data <= (others=>'0');
      loop
         wait until rising_edge(clk1x) and disc_req = '1';
         exit when sim_done = '1';
         for c in 0 to 2 loop wait until rising_edge(clk1x); end loop;
         disc_ack <= '1';
         for w in 0 to 511 loop
            disc_addr <= std_logic_vector(to_unsigned(w,9));
            disc_data <= disc_lba(7 downto 0) & std_logic_vector(to_unsigned(w mod 256,8));
            disc_wr <= '1'; wait until rising_edge(clk1x);
         end loop;
         disc_wr <= '0'; disc_ack <= '0';
      end loop;
   end process;
   -- monitor: print every distinct disc_lba band the probe fires
   monitor : process
      variable l : line; variable prev : std_logic := '0';
   begin
      wait until rising_edge(clk1x);
      if disc_req = '1' and prev = '0' then
         write(l, string'("  [MARKER] disc_lba=0x")); hwrite(l, disc_lba); writeline(output,l);
      end if;
      prev := disc_req;
   end process;
   stim : process
      variable l : line;
   begin
      reset <= '1'; for i in 0 to 8 loop wait until rising_edge(clk1x); end loop; reset <= '0';
      write(l, string'("--- last-valid-PC test: run valid 0x800200E8, then jump WILD 0xA7CA0DF8 ---")); writeline(output,l);
      write(l, string'("--- expect: origin_pc(ph0-3)=0x800200E8, bad_pc(ph4-7)=0xA7CA0DF8 ---")); writeline(output,l);
      cpu_pc_tb <= x"800200E8";                                        -- valid (RAM)
      for i in 0 to 200 loop wait until rising_edge(clk1x); end loop;
      cpu_pc_tb <= x"A7CA0DF8";                                        -- jump WILD (unmapped) -> triggers capture
      for i in 0 to 12000 loop wait until rising_edge(clk1x); end loop; -- let all 8 phases emit
      write(l, string'("--- DONE ---")); writeline(output,l);
      sim_done <= '1'; wait;
   end process;
end architecture;
