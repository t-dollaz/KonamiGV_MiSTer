# GV-only trim plan (pre-implementation survey)

Goal: remove every PSX subsystem no GV title can ever exercise, keep faithful
skeletons of everything the BIOS/game touches, and repurpose the freed
resources (the device sits at ~98% ALM). Sources: MAME `konamigv.cpp` machine
config + per-game maps, the ZV610 board facts (JAMMA-only I/O — no controller
ports or memcard slots exist physically; NaokiS28 KiCad repo), the working
DuckStation-SB boot log, and the fork's live instantiation list.

Sequencing rule (project law since June): one subsystem per build, full NVC
suite green in between, never mid-bug-hunt. This milestone starts only after
the operator/TEST menu is confirmed working on hardware.

## Remove entirely — unreachable from any GV title

| Subsystem | Files / anchor points | Safety argument | ALMs freed |
|---|---|---|---|
| Memory cards (x2) | memcard.vhd x2, joypad_mem.vhd, HPS mounts, DDR3 regions | no slots on board; arcade sw has no memcard concept | TBD (fit rpt) |
| Controller device emulation | joypad_pad.vhd (digital/analog/mouse/GunCon/NeGcon/multitap models) | GV inputs = JAMMA via EXP1; our button wiring taps the joypad1 input record in PSX.sv, not the SIO device | TBD |
| Savestates + rewind | savestates.vhd, statemanager.vhd, savestate_ui.sv, ~200 SS_* points in psx_top, DDR3 SS region | arcade-meaningless; frees ddr3_savestate arbiter gating; our flash region overlaps it | TBD |
| Cheat engine | cheats.vhd + OSD | nothing to cheat; frees BRAM | TBD |
| PSX gun DEVICE emulation only | the GunCon/Justifier device models inside joypad_pad.vhd (leave with it) | Dead Eye's gun is EXP1 memory-mapped (GUNX1 @0x1F680080, konamigv.cpp:437), not a PSX pad-bus gun | (part of joypad_pad) |
| BIOS patching | fastboot / PATCHSERIAL in memorymux | Sony-BIOS offsets; corrupts the GV BIOS if ever enabled | ~0 (safety) |

## Keep a faithful skeleton — BIOS/game touches it

| Subsystem | Skeleton form | Evidence |
|---|---|---|
| SIO0 registers (joypad.vhd core) | register protocol with NO devices (pad-absent = no /ACK -> BIOS timeout path) | boot code polls SIO0 constantly (DuckStation logs) |
| EXP2 POST port (exp2.vhd) | keep as-is (3KB) | BIOS writes POST codes 0F..07 every boot |
| MEMCTRL | keep fully | game reconfigures EXP1 bus width pre-security-check (the flagship bring-up bug) |
| DUART @0x1F680000 | 0xFF stub (done, build #20) | konamigv.cpp:407 |
| Watchdog @0x1F780000 | no-op (done) | konamigv.cpp:410 |
| P3/P4 @0x1F100008 | all-1s idle (done, build #20) | konamigv.cpp:405 |
| SIO1 (sio.vhd) | keep as-is (4KB — not worth the risk) | — |

## Verify first / scope-dependent

- **MDEC + DMA ch0/1** (mdec.vhd — one of the largest modules): for a
  SIMPBOWL-ONLY build, zero MDEC activity in the working DuckStation
  boot->gameplay log (39 s window; verify a full attract loop before
  removing). **For a general GV core: KEEP** — Tokimeki (tmosh*) and Wedding
  Rhapsody are stills/FMV-heavy titles of the era that almost certainly
  decode via MDEC, and fabricore's System573 core deliberately kept MDEC
  dormant for the same reason. If removed, make it a build variant, not a
  deletion.
- **Savestates**: recommendation stands (remove) but note the counter-example:
  fabricore kept savestates as a DEBUG TOOL (their .ss files feed VRAM
  extraction tooling). We built the disc-fd telemetry channel instead, so our
  debug story does not depend on them, and the ALM pressure argues removal.
- **PAL video paths**: GV is NTSC; removal is interwoven in gpu_videoout —
  low payoff, high touch-count. Default: keep.

## All-nine-GV-games check (what a GENERAL GV core must ADD, not trim)

The remove-list above holds for every GV title (all are JAMMA-input,
memcard-less, PSX-pad-less — board-confirmed). But full coverage needs:
- **P3/P4 real inputs** (Nagano '98 / Hyper Athlete multiplayer): wire MiSTer
  players 3/4 into the P3_P4 port (currently correct-idle stub).
- **Second trackball** (Beat the Champ): two uPD4701s on split byte lanes +
  the btc reset port @0x1F680088 (konamigv.cpp btchamp_map).
- **Main-board 28F400 flash @0x1F380000** (btchamp, kdeadeye): SHARP_LH28F400
  16-bit device — reuse the 29F016A engine pattern; also the natural NVRAM
  home for those titles' persistence.
- **GUNX/GUNY ports + framework lightgun coords** (Dead Eye): EXP1
  memory-mapped (konamigv.cpp:437-440) fed from MiSTer analog/lightgun
  inputs. KEEP justifier_sensor.vhd + gpu_crosshair.vhd (~trivial ALMs):
  the crosshair overlay serves USB-gun play directly, and the Justifier
  beam-timing conversion is the proven seed for emulating the daughtercard's
  pulse->coordinate circuit if real photodiode-gun-on-CRT (SNAC) support is
  ever wanted. Only the GunCon/Justifier PAD-BUS device models (inside
  joypad_pad) are removed.
- **Tokimeki specialty I/O** (heartbeat/GSR/printer): niche; explicitly out
  of scope unless someone asks.

## System 573 compatibility notes (fabricore-eng/System573_MiSTer)

Their core is ALSO a patched PSX_MiSTer — directly comparable. Deltas that
matter if this codebase ever converges with 573 work:
- **SIO1 is LOAD-BEARING on 573**: the security cassette asserts DSR into
  SIO1_STAT bit 7 and the BIOS presence check polls it (their patch 0024,
  hardware-verified). Our "keep sio.vhd" call is now a hard requirement in
  any shared-lineage future. Never trim SIO1.
- Their 573 device set (ATAPI, x76f041/zs01 security carts, 16MB NOR +
  **s573_flash_saver.v**, MP3 digital I/O, M48T58 RTC, JVS stub) lives in
  their repo — a GV core need not duplicate it.
- **s573_flash_saver.v is prior art for our phase-2 flash write-back**
  (same 29F016A chip family, same MiSTer HPS environment) — study it before
  designing the high-score persistence saver.

## Repurpose

- Memcard S-slots + the memcard save-FSM pattern -> the 8MB flash write-back
  (high-score persistence, phase 2 of FLASH_WRITE_DESIGN.md). Third reuse of
  that skeleton (EEPROM saver was the second).
- Freed ALMs/BRAM -> timing margin (seed sweeps stop being load-bearing) and
  headroom for rev-0 GPU (CXD8514Q) quirk work if another title needs it
  (ZV610 README: rev-0 GPU "has quirks vs later GPUs" — PSX_MiSTer models a
  later revision; no observed impact on Simpsons Bowling).
- gpu_overlay stays: framework diagnostics.

## Resource numbers

To be filled from the build #21 PSX.fit.rpt "Fitter Resource Usage by Entity"
section. Historical anchor: cd_top removal freed ~2.9k ALMs.
