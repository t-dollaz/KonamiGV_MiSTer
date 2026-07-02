# Konami GV ("Baby Phoenix") — MiSTer FPGA core

## This is an experimental core and is not endorsed or tested by the MiSTer community at large. My only goal was to get Simpsons Bowling working. This may not be wired correctly for full GV support.

A MiSTer core for Konami's GV arcade system, built from the
[PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) core by Robert Peip
(FPGAzumSpass). The GV is a PlayStation-based arcade board: retail PSX silicon
plus a small set of Konami devices on the EXP1 expansion bus. This core's
first (and currently only tested) title is **Simpsons Bowling (GQ829 UAA)**,
which boots, passes its security check, and plays on real hardware.

> Naming note: "Baby Phoenix / GV System" is frequently confused with
> Konami's later System 573 (ATAPI CD, security carts, Bemani). They are
> different boards. This core is GV: SCSI CD-ROM, parallel flash, and a
> 93C46-class EEPROM. The authoritative hardware reference is MAME's
> `konamigv.cpp`, not `ksys573.cpp`.

## ⚠️ Do NOT use the Service Mode toggle without backing up your EEPROM first

The OSD has a `Service Mode` switch (the cabinet's TEST button). **Before
ever turning it on, copy your known-good `simpbowl.sav` somewhere safe.**

Why: when Simpsons Bowling sees TEST asserted, its test-mode entry runs a
**destructive EEPROM self-test** — it overwrites the entire EEPROM with a
walking bit pattern, intending to verify and then restore it. The very next
step is a **flash write test, which cannot pass on this core**: the flash is
currently read-only, faithful to the DuckStation-SB reference (`konami.cpp`
ignores flash data writes), whereas the real board has four writable Fujitsu
29F016A chips (MAME `konamigv.cpp:697-706`). The game reports
`FLASH-ROM CHECK: BAD` and aborts test-mode entry **without ever restoring
the EEPROM** — and since the core faithfully persists EEPROM writes to
`simpbowl.sav`, your security code is now gone. Every subsequent boot ends
at the security code error screen.

Recovery: overwrite `/media/fat/games/PSX/573/simpbowl.sav` with your backup
and reboot the core. (Holding SERVICE+TEST — the MAME-documented fresh-EEPROM
init — does not help: that path aborts at the same flash check.)

A proper fix (a 29F016A write path matching MAME's flash emulation, which
would make the operator/test menu actually reachable) is designed in
`docs/FLASH_WRITE_DESIGN.md` and in progress.

## What this board is

```
 ┌──────────────────────────────────────────────────────────────┐
 │  PlayStation base (unmodified PSX_MiSTer datapath)           │
 │  R3000A CPU · GTE · GPU (VRAM in DDR3) · SPU · DMA · IRQ     │
 │  2 MB main RAM (SDRAM) · 512 KB Konami BIOS (999A01.7E)      │
 └──────────────┬───────────────────────────────────────────────┘
                │ EXP1 bus @ 0x1F000000 (rtl/konami573.vhd)
 ┌──────────────┴───────────────────────────────────────────────┐
 │  0x1F000000  NCR 53CF96 SCSI (register-level model)          │
 │              disc data via HPS sd_* mount → DMA channel 5    │
 │              completion interrupt on IRQ10                   │
 │  0x1F100000  JAMMA P1/P2 inputs                              │
 │  0x1F180080  128-byte EEPROM window (holds the security code)│
 │  0x1F680080  4×2 MB flash (interleaved, served from DDR3)    │
 │  0x1F6800C0  µPD4701-class trackball counters                │
 │  0x1F780000  watchdog (no-op)                                │
 └──────────────────────────────────────────────────────────────┘
```

The 573-numbered file names are historical (the project began under the
573 misnomer); the hardware modeled is GV.

Behavioral ground truth is the Arcade1Up `duckstation-sb` fork's
`src/core/konami.cpp` (~530 lines) — the shipping emulator for this exact
game — cross-checked against MAME's `konamigv.cpp`. Several hard-won
bring-up bugs came down to matching that reference's exact bus semantics;
see `docs/BRINGUP_NOTES.md`.

## Core build status

Boots and plays Simpsons Bowling on a DE10-nano-class board (HDMI + VGA,
both timing corners met on the shipping build).

| Component | State | Notes |
|---|---|---|
| SCSI 53CF96 register model | ✅ tested on hw | full boot handshake, READ(10), triple-read patterns |
| Disc→RAM path (DMA ch5, HPS sd mount) | ✅ tested on hw | 2048 B flat sectors; out-of-range reads complete gracefully |
| IRQ10 (SCSI interrupt) | ✅ measured on hw | delivery & CPU-ack counted 1:1 |
| 4×2 MB flash from DDR3 | ✅ tested on hw | read-wait design; 16-bit address-register writes reassembled |
| EEPROM window + save mount | ✅ tested on hw | auto-load on mount, dirty write-back, security check passes |
| EXP1 sub-word semantics | ✅ tested on hw | byte/16/32-bit lanes match konami.cpp exactly; MEMCTRL bus-width reconfig ignored (as the reference does) |
| JAMMA inputs (pad→P1 map) | ✅ tested on hw | Buttons in use: Start must be pressed to begin the game. After pressing start, PSX pad input "X" is used for action button. Select = COIN1, R2 = SERVICE1 (per `konamigv.cpp` INPUT_PORTS) |
| Trackball | ✅ tested on hw, NOT with any kind of trackball, just a USB mouse | mouse-driven; per-packet edge fix, OSD speed divider (1x…1/8) + OSD invert (X/Y/X+Y) |
| Service Mode (TEST switch) | ⚠️ delivery works, menu blocked | OSD toggle reaches the game (P1 bit 12), but test-mode entry dies at the flash write check — **see the EEPROM warning above**; fix designed in `docs/FLASH_WRITE_DESIGN.md` |
| Flash writes (29F016A program/erase) | 🏗️ in progress | read path is done/tested; write path per MAME `intelfsh` is the current work item |
| On-chip telemetry | ✅ kept aboard | access-ring/IRQ counters emitted via disc-fd marker channel |
| Other GV titles (8 more) | 📋 untested | same device set; expected close |
| Dead Eye light gun (GUNX/GUNY) | ❌ not implemented | only GV title needing it |
| Tokimeki heartbeat/printer I/O | ❌ not implemented | specialty hardware |
| GV-only trim (remove PSX CD/SIO/memcard/savestates) | 📋 planned | frees ~timing/power headroom; PSX cd_top already removed |

Utilization is ~98% ALM — timing closes but is placement-sensitive;
clean full compiles only (no incremental).

## Running it

You must supply your own dumps (none are included or linked here):
the GV BIOS `999a01.7e`, the four 2 MB flash dumps, a 128-byte EEPROM
image, and a Mode-1/2048 disc image of your disc.

1. Interleave the four flash dumps into the single image the core loads:
   `python3 tools/interleave_flash.py flash0 flash1 flash2 flash3 flash_573_simpbowl.bin`
2. On the MiSTer SD: core `.rbf` at `/media/fat/`, BIOS as the PSX core's
   `boot.rom`, flash image + EEPROM under `/media/fat/games/PSX/573/`,
   disc image anywhere reachable.
3. Launch via the MGL in `mgl/` (mounts EEPROM, flash, and disc in one
   shot). OSD: `Load 573 Flash` (F2), `Mount 573 Disc` (S4),
   `573 EEPROM Save` (S0), `Trackball Speed`, `Trackball Invert`,
   `Service Mode` (**read the EEPROM warning at the top first**).
4. Back up your working `simpbowl.sav` now, while it's known-good.

## Building / testing

Synthesis: Quartus Prime Lite **17.0.2**, Cyclone V. Always run clean
full compiles (`quartus_sh --flow compile PSX` after wiping
`db/ incremental_db/ output_files/`) — at this utilization, incremental
builds lie about timing.

Simulation (NVC ≥ 1.21, VHDL-2008): the benches in `sim_gv/` drive the
real `memorymux.vhd` + `konami573.vhd` end to end — including the exact
security-check access under the game's 16-bit EXP1 bus configuration:

```
cd sim_gv
nvc --std=2008 --work=mem -a --relaxed RamMLAB_stub.vhd ../rtl/SyncFifoFallThroughMLAB.vhd
nvc --std=2008 -L. --work=work_nvc -a --relaxed dpram_dif_stub.vhd ../rtl/konami573.vhd ../rtl/memorymux.vhd tb_memmux.vhd
nvc --std=2008 -L. --work=work_nvc -e tb_memmux -r tb_memmux          # 34 checks
nvc --std=2008 -L. --work=work_nvc -a --relaxed tb_konami573_boot.vhd
nvc --std=2008 -L. --work=work_nvc -e tb_konami573_boot -r tb_konami573_boot --stop-time=2ms   # 26 checks
nvc --std=2008 -L. --work=work_nvc -a --relaxed tb_flash.vhd
nvc --std=2008 -L. --work=work_nvc -e tb_flash -gDDR3_LAT=20 -r tb_flash   # 0 stale expected
```

## License

GPL-2.0, matching PSX_MiSTer and the MiSTer framework.

Credits: Robert Peip (FPGAzumSpass) for the extraordinary PSX core this
stands on; the MAME team's `konamigv.cpp` for authoritative hardware
facts; the Arcade1Up `duckstation-sb` fork's `konami.cpp` as the
behavioral reference; psx-spx for PSX platform documentation.
