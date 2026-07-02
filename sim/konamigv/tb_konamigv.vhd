library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library psx;
library tb;
use tb.globals.all;

-- Full-system NVC testbench for the Konami GV (Baby Phoenix) fork of PSX_MiSTer.
-- Differences from the fabricore System 573 harness (tb_system573.vhd):
--   * No external EXP1 ports — konami573.vhd is integrated inside psx_top.
--     The peripheral (SCSI, watchdog, EEPROM, P1) is already wired internally;
--     no EXP1 responder needed in this harness.
--   * disc_*, flash_dl_*, eeprom_* ports tied off (GV HPS disc not functional in sim).
--   * hasCD='0' — GV uses its own disc channel, not the PSX CD subsystem.
--   * BIOS file: gv_bios.bin (must be placed in build/ before running).
--   * PC tap path: .tb_konamigv.ipsx_mister.ipsx_top.icpu.PC
--
-- Outputs in build/:
--   pc_trace.log   — non-sequential PC jumps (boot progress)
--   bios_fetch.log — SDRAM reads in BIOS region (confirms CPU is fetching BIOS)

entity tb_konamigv is
   generic (
      TURBO    : std_logic := '1';  -- '1' enables TURBO_MEM/COMP/CACHE
      SLOWVRAM : integer   := 0     -- DDRRAM model latency (0=fast bring-up)
   );
end entity;

architecture sim of tb_konamigv is

   -- ─── Clocks ─────────────────────────────────────────────────────────────────
   signal clk1x  : std_logic := '1';
   signal clk2x  : std_logic := '1';
   signal clk3x  : std_logic := '1';
   signal clkvid : std_logic := '1';
   signal reset  : std_logic := '1';

   -- ─── PC tap (routed via cpu_pc_dbg_out port on psx_top / psx_mister) ──────────
   -- cpu_pc_dbg = pcOld1 (1-cycle delayed) — adequate for jump tracing
   signal cpu_pc             : unsigned(31 downto 0);

   -- ─── Main RAM + BIOS (SDRAM) ─────────────────────────────────────────────────
   signal ram_refresh        : std_logic;
   signal ram_dataWrite      : std_logic_vector(31 downto 0);
   signal ram_dataRead32     : std_logic_vector(31 downto 0);
   signal ram_Adr            : std_logic_vector(24 downto 0);
   signal ram_cntDMA         : std_logic_vector(1 downto 0);
   signal ram_be             : std_logic_vector(3 downto 0);
   signal ram_rnw            : std_logic;
   signal ram_ena            : std_logic;
   signal ram_dma            : std_logic;
   signal ram_iscache        : std_logic;
   signal ram_done           : std_logic;
   signal ram_dmafifo_adr    : std_logic_vector(22 downto 0);
   signal ram_dmafifo_data   : std_logic_vector(31 downto 0);
   signal ram_dmafifo_empty  : std_logic;
   signal ram_dmafifo_read   : std_logic;
   signal cache_wr           : std_logic_vector(3 downto 0);
   signal cache_data         : std_logic_vector(31 downto 0);
   signal cache_addr         : std_logic_vector(7 downto 0);
   signal dma_wr             : std_logic;
   signal dma_reqprocessed   : std_logic;
   signal dma_data           : std_logic_vector(31 downto 0);

   -- ─── SPU RAM (SDRAM, second instance) ────────────────────────────────────────
   signal spuram_dataWrite   : std_logic_vector(31 downto 0);
   signal spuram_Adr         : std_logic_vector(18 downto 0);
   signal spuram_be          : std_logic_vector(3 downto 0);
   signal spuram_rnw         : std_logic;
   signal spuram_ena         : std_logic;
   signal spuram_dataRead    : std_logic_vector(31 downto 0);
   signal spuram_done        : std_logic;

   -- ─── VRAM (DDRRAM) ───────────────────────────────────────────────────────────
   signal DDRAM_BUSY         : std_logic;
   signal DDRAM_BURSTCNT     : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR         : std_logic_vector(28 downto 0);
   signal DDRAM_DOUT         : std_logic_vector(63 downto 0);
   signal DDRAM_DOUT_READY   : std_logic;
   signal DDRAM_RD           : std_logic;
   signal DDRAM_DIN          : std_logic_vector(63 downto 0);
   signal DDRAM_BE           : std_logic_vector(7 downto 0);
   signal DDRAM_WE           : std_logic;

   -- ─── Video outputs (captured by framebuffer entity) ──────────────────────────
   signal hsync              : std_logic;
   signal vsync              : std_logic;
   signal hblank             : std_logic;
   signal vblank             : std_logic;
   signal video_ce           : std_logic;
   signal video_interlace    : std_logic;
   signal video_r            : std_logic_vector(7 downto 0);
   signal video_g            : std_logic_vector(7 downto 0);
   signal video_b            : std_logic_vector(7 downto 0);
   signal DisplayWidth       : unsigned(10 downto 0);
   signal DisplayHeight      : unsigned(9 downto 0);
   signal DisplayOffsetX     : unsigned(9 downto 0);
   signal DisplayOffsetY     : unsigned(8 downto 0);

   -- ─── BIOS load constants ─────────────────────────────────────────────────────
   -- SDRAM byte offset for physical 0x1FC00000 (BIOS ROM region).
   -- Same value as the fabricore 573 harness — the PSX memory map is identical.
   constant BIOS_TARGET : integer := 16#800000#;

   -- ─── Exe header (unused but required by sdram_model3x port list) ─────────────
   signal exe_initial_pc   : unsigned(31 downto 0);
   signal exe_initial_gp   : unsigned(31 downto 0);
   signal exe_load_address : unsigned(31 downto 0);
   signal exe_file_size    : unsigned(31 downto 0);
   signal exe_stackpointer : unsigned(31 downto 0);

begin

   -- ─── Clock generation ─────────────────────────────────────────────────────────
   -- PSX: clk1x ≈ 33.8688 MHz, clk2x ≈ 67.7376 MHz, clk3x ≈ 100 MHz
   clk1x  <= not clk1x  after 14764 ps;   -- 33.868 MHz half-period
   clk2x  <= not clk2x  after  7382 ps;   -- 67.737 MHz
   clk3x  <= not clk3x  after  5000 ps;   -- 100 MHz
   clkvid <= not clkvid  after 13468 ps;   -- ~37.136 MHz (NTSC pixel clock)

   reset <= '1', '0' after 200 ns;

   -- ─── DUT: GV fork of psx_mister ──────────────────────────────────────────────
   -- konami573 is instantiated INSIDE psx_top, so no EXP1 ports appear here.
   -- disc_*, flash_dl_*, eeprom_* are all tied off — the sim goal is confirming
   -- CPU execution advances past the color-bar crash (i-cache patches), not
   -- exercising the SCSI or flash paths.
   ipsx_mister : entity psx.psx_mister
      generic map (is_simu => '1')
      port map (
         clk1x                 => clk1x,
         clk2x                 => clk2x,
         clk3x                 => clk3x,
         clkvid                => clkvid,
         reset                 => reset,
         isPaused              => open,
         pause                 => '0',
         hps_busy              => '0',
         loadExe               => '0',
         exe_initial_pc        => (others => '0'),
         exe_initial_gp        => (others => '0'),
         exe_load_address      => (others => '0'),
         exe_file_size         => (others => '0'),
         exe_stackpointer      => (others => '0'),
         fastboot              => '1',
         ram8mb                => '0',
         TURBO_MEM             => TURBO,
         TURBO_COMP            => TURBO,
         TURBO_CACHE           => TURBO,
         TURBO_CACHE50         => '0',
         REPRODUCIBLEGPUTIMING => '0',
         INSTANTSEEK           => '0',
         FORCECDSPEED          => "000",
         LIMITREADSPEED        => '0',
         IGNORECDDMATIMING     => '0',
         ditherOff             => '0',
         interlaced480pHack    => '0',
         showGunCrosshairs     => '0',
         enableNeGconRumble    => '0',
         fpscountOn            => '0',
         cdslowOn              => '0',
         testSeek              => '0',
         pauseOnCDSlow         => '0',
         errorOn               => '0',
         LBAOn                 => '0',
         PATCHSERIAL           => '0',
         noTexture             => '0',
         textureFilter         => "00",
         textureFilterStrength => "00",
         textureFilter2DOff    => '0',
         dither24              => '0',
         render24              => '0',
         drawSlow              => '0',
         syncVideoOut          => '0',
         syncInterlace         => '0',
         rotate180             => '0',
         fixedVBlank           => '0',
         vCrop                 => "00",
         hCrop                 => '0',
         SPUon                 => '1',
         SPUIRQTrigger         => '0',
         SPUSDRAM              => '1',
         REVERBOFF             => '0',
         REPRODUCIBLESPUDMA    => '0',
         WIDESCREEN            => "00",
         oldGPU                => '0',
         -- RAM/BIOS
         biosregion            => "00",
         ram_refresh           => ram_refresh,
         ram_dataWrite         => ram_dataWrite,
         ram_dataRead32        => ram_dataRead32,
         ram_Adr               => ram_Adr,
         ram_cntDMA            => ram_cntDMA,
         ram_be                => ram_be,
         ram_rnw               => ram_rnw,
         ram_ena               => ram_ena,
         ram_dma               => ram_dma,
         ram_cache             => ram_iscache,
         ram_done              => ram_done,
         ram_dmafifo_adr       => ram_dmafifo_adr,
         ram_dmafifo_data      => ram_dmafifo_data,
         ram_dmafifo_empty     => ram_dmafifo_empty,
         ram_dmafifo_read      => ram_dmafifo_read,
         cache_wr              => cache_wr,
         cache_data            => cache_data,
         cache_addr            => cache_addr,
         dma_wr                => dma_wr,
         dma_reqprocessed      => dma_reqprocessed,
         dma_data              => dma_data,
         -- VRAM
         DDRAM_BUSY            => DDRAM_BUSY,
         DDRAM_BURSTCNT        => DDRAM_BURSTCNT,
         DDRAM_ADDR            => DDRAM_ADDR,
         DDRAM_DOUT            => DDRAM_DOUT,
         DDRAM_DOUT_READY      => DDRAM_DOUT_READY,
         DDRAM_RD              => DDRAM_RD,
         DDRAM_DIN             => DDRAM_DIN,
         DDRAM_BE              => DDRAM_BE,
         DDRAM_WE              => DDRAM_WE,
         -- CD: GV doesn't use the PSX CD subsystem; hasCD='0' keeps it idle
         region                => "00",
         region_out            => open,
         hasCD                 => '0',
         LIDopen               => '0',
         fastCD                => '0',
         trackinfo_data        => (others => '0'),
         trackinfo_addr        => (others => '0'),
         trackinfo_write       => '0',
         resetFromCD           => open,
         cd_hps_req            => open,
         cd_hps_lba            => open,
         cd_hps_lba_sim        => open,
         cd_hps_ack            => '0',
         cd_hps_write          => '0',
         cd_hps_data           => (others => '0'),
         -- GV disc channel (tied off — disc FSM won't be exercised in sim)
         disc_req              => open,
         disc_lba              => open,
         disc_ack              => '0',
         disc_wr               => '0',
         disc_addr             => (others => '0'),
         disc_data             => (others => '0'),
         disc_mounted          => '0',
         -- GV flash download (tied off)
         flash_dl_req          => '0',
         flash_dl_addr         => (others => '0'),
         flash_dl_data         => (others => '0'),
         flash_dl_done         => open,
         -- GV EEPROM save (tied off)
         eeprom_load           => '0',
         eeprom_save           => '0',
         eeprom_mounted        => '0',
         eeprom_rd             => open,
         eeprom_wr             => open,
         eeprom_ack            => '0',
         eeprom_write          => '0',
         eeprom_addr           => (others => '0'),
         eeprom_dataIn         => (others => '0'),
         eeprom_dataOut        => open,
         -- SPU RAM
         spuram_dataWrite      => spuram_dataWrite,
         spuram_Adr            => spuram_Adr,
         spuram_be             => spuram_be,
         spuram_rnw            => spuram_rnw,
         spuram_ena            => spuram_ena,
         spuram_dataRead       => spuram_dataRead,
         spuram_done           => spuram_done,
         -- Memcard (tied off — not relevant for arcade boot)
         memcard_changed       => open,
         saving_memcard        => open,
         memcard1_load         => '0',
         memcard2_load         => '0',
         memcard_save          => '0',
         memcard1_mounted      => '0',
         memcard1_available    => '0',
         memcard1_rd           => open,
         memcard1_wr           => open,
         memcard1_lba          => open,
         memcard1_ack          => '0',
         memcard1_write        => '0',
         memcard1_addr         => (others => '0'),
         memcard1_dataIn       => (others => '0'),
         memcard1_dataOut      => open,
         memcard2_mounted      => '0',
         memcard2_available    => '0',
         memcard2_rd           => open,
         memcard2_wr           => open,
         memcard2_lba          => open,
         memcard2_ack          => '0',
         memcard2_write        => '0',
         memcard2_addr         => (others => '0'),
         memcard2_dataIn       => (others => '0'),
         memcard2_dataOut      => open,
         -- Video
         videoout_on           => '1',
         isPal                 => '0',
         pal60                 => '0',
         hsync                 => hsync,
         vsync                 => vsync,
         hblank                => hblank,
         vblank                => vblank,
         DisplayWidth          => DisplayWidth,
         DisplayHeight         => DisplayHeight,
         DisplayOffsetX        => DisplayOffsetX,
         DisplayOffsetY        => DisplayOffsetY,
         video_ce              => video_ce,
         video_interlace       => video_interlace,
         video_r               => video_r,
         video_g               => video_g,
         video_b               => video_b,
         video_isPal           => open,
         video_fbmode          => open,
         video_fb24            => open,
         video_hResMode        => open,
         video_frameindex      => open,
         -- Joypad / keys (all tied off for bare boot)
         DSAltSwitchMode       => '0',
         PadPortEnable1        => '0',
         PadPortDigital1       => '0',
         PadPortAnalog1        => '0',
         PadPortMouse1         => '0',
         PadPortGunCon1        => '0',
         PadPortneGcon1        => '0',
         PadPortWheel1         => '0',
         PadPortDS1            => '0',
         PadPortJustif1        => '0',
         PadPortStick1         => '0',
         PadPortPopn1          => '0',
         PadPortEnable2        => '0',
         PadPortDigital2       => '0',
         PadPortAnalog2        => '0',
         PadPortMouse2         => '0',
         PadPortGunCon2        => '0',
         PadPortneGcon2        => '0',
         PadPortWheel2         => '0',
         PadPortDS2            => '0',
         PadPortJustif2        => '0',
         PadPortStick2         => '0',
         PadPortPopn2          => '0',
         KeyTriangle           => (others => '0'),
         KeyCircle             => (others => '0'),
         KeyCross              => (others => '0'),
         KeySquare             => (others => '0'),
         KeySelect             => (others => '0'),
         KeyStart              => (others => '0'),
         KeyRight              => (others => '0'),
         KeyLeft               => (others => '0'),
         KeyUp                 => (others => '0'),
         KeyDown               => (others => '0'),
         KeyR1                 => (others => '0'),
         KeyR2                 => (others => '0'),
         KeyR3                 => (others => '0'),
         KeyL1                 => (others => '0'),
         KeyL2                 => (others => '0'),
         KeyL3                 => (others => '0'),
         ToggleDS              => (others => '0'),
         Analog1XP1            => (others => '0'),
         Analog1YP1            => (others => '0'),
         Analog2XP1            => (others => '0'),
         Analog2YP1            => (others => '0'),
         Analog1XP2            => (others => '0'),
         Analog1YP2            => (others => '0'),
         Analog2XP2            => (others => '0'),
         Analog2YP2            => (others => '0'),
         Analog1XP3            => (others => '0'),
         Analog1YP3            => (others => '0'),
         Analog2XP3            => (others => '0'),
         Analog2YP3            => (others => '0'),
         Analog1XP4            => (others => '0'),
         Analog1YP4            => (others => '0'),
         Analog2XP4            => (others => '0'),
         Analog2YP4            => (others => '0'),
         multitap              => '0',
         multitapDigital       => '0',
         multitapAnalog        => '0',
         MouseEvent            => '0',
         MouseLeft             => '0',
         MouseRight            => '0',
         MouseX                => (others => '0'),
         MouseY                => (others => '0'),
         RumbleDataP1          => open,
         RumbleDataP2          => open,
         RumbleDataP3          => open,
         RumbleDataP4          => open,
         padMode               => open,
         -- SNAC (tied off)
         snacPort1             => '0',
         snacPort2             => '0',
         irq10Snac             => '0',
         actionNextSnac        => '0',
         receiveValidSnac      => '0',
         ackSnac               => '0',
         snacMC                => '0',
         receiveBufferSnac     => (others => '0'),
         transmitValueSnac     => open,
         selectedPort1Snac     => open,
         selectedPort2Snac     => open,
         clk9Snac              => open,
         beginTransferSnac     => open,
         -- Sound (to open — no audio output in this harness)
         sound_out_left        => open,
         sound_out_right       => open,
         -- Savestates (disabled)
         increaseSSHeaderCount => '0',
         save_state            => '0',
         load_state            => '0',
         savestate_number      => 0,
         state_loaded          => open,
         validSStates          => open,
         rewind_on             => '0',
         rewind_active         => '0',
         -- Cheats (disabled)
         cheat_clear           => '0',
         cheats_enabled        => '0',
         cheat_on              => '0',
         cheat_in              => (others => '0'),
         cheats_active         => open,
         Cheats_BusAddr        => open,
         Cheats_BusRnW         => open,
         Cheats_BusByteEnable  => open,
         Cheats_BusWriteData   => open,
         Cheats_Bus_ena        => open,
         Cheats_BusReadData    => (others => '0'),
         Cheats_BusDone        => '0',
         cpu_pc_out            => cpu_pc
      );

   -- ─── Main RAM + BIOS model ────────────────────────────────────────────────────
   -- SCRIPTLOADING='1' enables the globals.vhd COMMAND_FILE_* mechanism so the
   -- bios_load process below can preload gv_bios.bin into the SDRAM array at
   -- byte offset BIOS_TARGET (= physical 0x1FC00000) before the CPU starts.
   isdram_main : entity tb.sdram_model3x
      generic map (
         DOREFRESH     => '1',
         SCRIPTLOADING => '1'
      )
      port map (
         clk                  => clk1x,
         clk3x                => clk3x,
         refresh              => ram_refresh,
         addr(26 downto 25)   => "00",
         addr(24 downto 0)    => ram_Adr,
         req                  => ram_ena,
         ram_dma              => ram_dma,
         ram_dmacnt           => ram_cntDMA,
         ram_iscache          => ram_iscache,
         rnw                  => ram_rnw,
         be                   => ram_be,
         di                   => ram_dataWrite,
         do                   => open,
         do32                 => ram_dataRead32,
         done                 => ram_done,
         cache_wr             => cache_wr,
         cache_data           => cache_data,
         cache_addr           => cache_addr,
         dma_wr               => dma_wr,
         dma_data             => dma_data,
         reqprocessed         => dma_reqprocessed,
         ram_idle             => open,
         ram_dmafifo_adr      => ram_dmafifo_adr,
         ram_dmafifo_data     => ram_dmafifo_data,
         ram_dmafifo_empty    => ram_dmafifo_empty,
         ram_dmafifo_read     => ram_dmafifo_read,
         exe_initial_pc       => exe_initial_pc,
         exe_initial_gp       => exe_initial_gp,
         exe_load_address     => exe_load_address,
         exe_file_size        => exe_file_size,
         exe_stackpointer     => exe_stackpointer
      );

   -- ─── SPU RAM model ────────────────────────────────────────────────────────────
   -- Second sdram_model3x instance, no script loading — just a zero-initialised
   -- behavioral 512KB SRAM. SPU audio reads return 0 which is benign for boot.
   isdram_spu : entity tb.sdram_model3x
      generic map (
         DOREFRESH     => '0',
         SCRIPTLOADING => '0'
      )
      port map (
         clk                  => clk1x,
         clk3x                => clk3x,
         refresh              => '0',
         addr(26 downto 19)   => (others => '0'),
         addr(18 downto 0)    => spuram_Adr,
         req                  => spuram_ena,
         ram_dma              => '0',
         ram_dmacnt           => "00",
         ram_iscache          => '0',
         rnw                  => spuram_rnw,
         be                   => spuram_be,
         di                   => spuram_dataWrite,
         do                   => open,
         do32                 => spuram_dataRead,
         done                 => spuram_done,
         cache_wr             => open,
         cache_data           => open,
         cache_addr           => open,
         dma_wr               => open,
         dma_data             => open,
         reqprocessed         => open,
         ram_idle             => open,
         ram_dmafifo_adr      => (others => '0'),
         ram_dmafifo_data     => (others => '0'),
         ram_dmafifo_empty    => '1',
         ram_dmafifo_read     => open,
         exe_initial_pc       => open,
         exe_initial_gp       => open,
         exe_load_address     => open,
         exe_file_size        => open,
         exe_stackpointer     => open
      );

   -- ─── VRAM (DDRRAM) model ─────────────────────────────────────────────────────
   iddrram : entity tb.ddrram_model
      generic map (
         SLOWTIMING   => SLOWVRAM,
         RANDOMTIMING => '0'
      )
      port map (
         DDRAM_CLK        => clk2x,
         DDRAM_BUSY       => DDRAM_BUSY,
         DDRAM_BURSTCNT   => DDRAM_BURSTCNT,
         DDRAM_ADDR       => DDRAM_ADDR,
         DDRAM_DOUT       => DDRAM_DOUT,
         DDRAM_DOUT_READY => DDRAM_DOUT_READY,
         DDRAM_RD         => DDRAM_RD,
         DDRAM_DIN        => DDRAM_DIN,
         DDRAM_BE         => DDRAM_BE,
         DDRAM_WE         => DDRAM_WE
      );

   -- ─── Framebuffer capture ─────────────────────────────────────────────────────
   -- Writes gra_fb_out_vga.gra (640×480 video-out capture).
   -- Convert to PNG with: python3 tools/gra2png.py build/gra_fb_out_vga.gra out.png
   -- (The upstream framebuffer entity captures pixel-clock output only;
   --  the VRAM-direct tap from the fabricore harness is not available here.)
   iframebuffer : entity tb.framebuffer
      port map (
         clk             => clkvid,
         hblank          => hblank,
         vblank          => vblank,
         video_ce        => video_ce,
         video_interlace => video_interlace,
         video_r         => video_r,
         video_g         => video_g,
         video_b         => video_b
      );

   -- ─── BIOS preload ─────────────────────────────────────────────────────────────
   -- Uses the globals.vhd COMMAND_FILE_* package signals shared with sdram_model3x.
   -- gv_bios.bin must be present in the working directory (build/) before running.
   -- The run script copies it from GV_BIOS_SRC.
   bios_load : process
   begin
      COMMAND_FILE_START_1 <= '0';
      wait until reset = '0';
      wait until rising_edge(clk1x);
      -- Point the SDRAM model at the BIOS file and target offset
      COMMAND_FILE_ENDIAN  <= '0';
      COMMAND_FILE_NAME    <= (others => nul);
      COMMAND_FILE_NAME(1 to 11) <= "gv_bios.bin";
      COMMAND_FILE_NAMELEN <= 11;
      COMMAND_FILE_TARGET  <= BIOS_TARGET;
      COMMAND_FILE_OFFSET  <= 0;
      COMMAND_FILE_SIZE    <= 0;  -- 0 = load entire file
      COMMAND_FILE_START_1 <= '1';
      wait until COMMAND_FILE_ACK_1 = '1';
      COMMAND_FILE_START_1 <= '0';
      report "GV BIOS loaded into SDRAM at offset 0x" &
             integer'image(BIOS_TARGET) & " (phys 0x1FC00000)" severity note;
      wait;
   end process;

   -- ─── CPU PC trace ─────────────────────────────────────────────────────────────
   -- Logs every non-sequential PC jump to pc_trace.log.  Run check_boot.py against
   -- this file (or just grep for 0x1FC* to confirm the CPU is fetching BIOS code,
   -- and watch for the PC escaping 0x1FC* to confirm it reached game RAM).
   pc_tap : process
      variable pc_prev   : unsigned(31 downto 0) := (others => '0');
      variable pc_cur    : unsigned(31 downto 0);
      variable snapcount : integer := 0;
      file f        : text open write_mode is "pc_trace.log";
      variable lout : line;
   begin
      wait until reset = '0';
      loop
         wait until rising_edge(clk1x);
         pc_cur := cpu_pc;
         -- Log every non-sequential jump (branch/exception/call)
         if pc_cur /= pc_prev + 4 and pc_cur /= pc_prev then
            write(lout, "JUMP 0x" & to_hstring(pc_prev) &
                  " -> 0x" & to_hstring(pc_cur));
            writeline(f, lout);
         end if;
         -- Periodic snapshot every 2^22 cycles (~125 ms sim) regardless of direction
         snapcount := snapcount + 1;
         if (snapcount mod 4194304) = 0 then
            write(lout, "SNAP @" & integer'image(snapcount) &
                  " cycles PC=0x" & to_hstring(pc_cur));
            writeline(f, lout);
         end if;
         pc_prev := pc_cur;
      end loop;
   end process;

   -- ─── BIOS fetch tap ───────────────────────────────────────────────────────────
   -- Logs SDRAM reads in the BIOS region (ram_Adr >= 0x800000) to bios_fetch.log.
   -- Confirms the CPU is actually executing BIOS code (not spinning at reset vector).
   bios_tap : process
      file f        : text open write_mode is "bios_fetch.log";
      variable lout : line;
   begin
      wait until reset = '0';
      loop
         wait until rising_edge(clk1x);
         if ram_ena = '1' and ram_rnw = '1' and
            unsigned(ram_Adr) >= 16#800000# then
            write(lout, "BIOS_RD addr=0x" & to_hstring(unsigned(ram_Adr)));
            writeline(f, lout);
         end if;
      end loop;
   end process;

end architecture;
