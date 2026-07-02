# Bring-up notes — how Simpsons Bowling came to boot

A condensed record of the hardware bring-up, kept because nearly every
bug came down to a *semantic* difference from the behavioral reference
(Arcade1Up `konami.cpp` / DuckStation bus model) that simulation with the
wrong assumptions happily passed. If you port another GV title or another
PSX-based Konami board, read this first.

## The reference contract (learned the hard way)

DuckStation's bus calls each konami.cpp handler **once per CPU access, at
native width, with no byte-lane fixup**. Consequences a hardware
implementation must reproduce:

- A byte read at an odd offset returns the addressed **word's low byte**,
  not the odd byte. A 32-bit read returns the 16-bit value zero-extended.
- 16-bit register writes deliver the **full 16-bit value in one call**
  (our bus byte-steps them — the flash address registers at 0x1F680082/4/6
  need the high byte reassembled or FlashAddress silently truncates).
- `KonamiDmaControlWrite` intercepts **every** ch5 DMA control write
  before the DMA engine: to-device transfers (MODE SELECT parameters) are
  discarded wholesale and complete instantly; the busy bit is never
  stored. Model ch5 to-device as discard-and-complete.
- Failed/short disc reads (out-of-range LBA) **complete anyway** with a
  stale buffer (konami.cpp even ships with the error log commented out).
  Never let an unserviceable READ(10) hang the SCSI FSM.
- **The game reconfigures EXP1 MEMCTRL to 16-bit bus width** (write
  0x173F47 at pc 0x80064E80 — the very write Arcade1Up keyed their
  score-table hook on) right before its security check. DuckStation
  ignores EXP1 width; a core that honors it returns half a word for every
  16-bit read from an 8-bit device port. This was the final boss:
  the security check is `lhu(0x1F180084) == 0x0F08` (EEPROM word 2,
  triple-read-verified, fn at 0x8002C4D8), and honoring the width made it
  read ~0x0008 forever. Force EXP1 byte-stepping regardless of width.

## Other integration lessons

- **DDR3 arbiter read contract**: a requester must hold its request until
  its last DOUT_READY beat lands (see spu_ram.vhd) — the response bus is
  untagged and the vram-pause window is the only mutual exclusion.
- **hps_io mouse**: `ps2_mouse[24]` is a *toggle*, one flip per packet.
  Treat it as a level and each packet's delta accumulates millions of
  times (instant ±2048 counter saturation = hypersensitive/dead axes).
- **MGL mounts race core reset**: the S0 EEPROM mount pulse arrives while
  the flash ioctl download still holds the core in reset. Latch "mounted"
  as a level and auto-load once after reset releases, or the game sees an
  all-zeros EEPROM — which *passes* the checksum stage (0 == empty sum)
  and fails only at the security-code stage. Deeply misleading.
- **Boot vs game behavior differ**: the BIOS polls (works without IRQ10,
  byte-writes every register); the loaded game uses 16-bit accesses, the
  MODE SELECT sequence, and IRQ10. A core can boot flawlessly and die the
  moment game code takes over. Test both regimes.
- The MAME first-boot ceremony (TEST/SERVICE to program flash: chips
  3A/3B/7A/7B) never appears in this distribution model: flash and EEPROM
  ship pre-programmed as files, as on the Arcade1Up product.

## On-chip telemetry

The core carries a permanent probe: when the game halts, a ring of the
last 16 EXP1 accesses (with data bytes), a CDB counter, and IRQ10
delivery/ack counters are emitted as disc-seek offsets through the HPS
sd mount (`fd` position = encoded marker). Polling `/proc/<MiSTer
pid>/fdinfo` from the HPS decodes it — remote, cheap, no extra plumbing.
The disc-fetch timeout doubles as the mechanism that lets far-out marker
"reads" complete. This channel found most of the bugs above.
