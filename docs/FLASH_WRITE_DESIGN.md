# GV Flash Write Path — 29F016A Command Engine (design, pre-implementation)

Goal: make the simpbowl daughtercard flash WRITABLE so the game's TEST-mode flash
check passes and the operator menu becomes reachable. Today the core follows
DuckStation-SB konami.cpp:375-377 (`case 0: // Ignored`) — but hardware truth is
MAME konamigv.cpp:697-706: `flash_w` case 0 writes through to four
`FUJITSU_29F016A` chips (config at konamigv.cpp:731-734), i.e. full AMD
command-set devices (machine/intelfsh.cpp). The Service-Mode campaign (2026-07-02)
proved the game's TEST path hard-requires this: EEPROM stomped + FLASH BAD +
stuck screen every time, on our core AND (predictably) on DuckStation-SB.

## Authority chain (cite-before-change)
- konamigv.cpp:697-706 — GV glue: one 16-bit data-port write = lo-chip
  `write(FA & 0x1FFFFF, data & 0xFF)` + hi-chip `write(..., data >> 8)`;
  chip pair selected by `FA >= 0x200000`. FA NOT incremented on writes.
- konamigv.cpp:675-689 — flash_r: read always increments FA; offset 8 sets FA|=1.
  (Both already implemented; reads keep this glue regardless of chip mode.)
- intelfsh.cpp fujitsu_29f016a_device: 8-bit, 0x200000 bytes, MFG_FUJITSU(0x04),
  device 0xAD, uniform 64KB sectors (no 4k/16k/boot flags).
- intelfsh.cpp write_full/read_full — the AMD mode FSM (subset below).

## Chip FSM (per byte lane — TWO independent FSMs, lo + hi)
The EXP1 bus byte-steps 16-bit writes; bstep0 carries the lo byte -> lo-chip FSM,
bstep1 the hi byte -> hi-chip FSM. This maps 1:1 onto MAME's per-chip write calls.
Command address = chip addr = FA & 0x1FFFFF; unlock matches use (addr & 0xFFF).

States (intelfsh FM_*): NORMAL, AMDID1, AMDID2, AMDID3(ID mode), ERASEAMD1..3,
ERASING (=FM_ERASEAMD4), BYTEPROGRAM, READID.

Transitions (29F016A-relevant subset, from write_full):
- NORMAL/AMDID3/READID + data 0xF0 or 0xFF        -> NORMAL   (reset)
- NORMAL/AMDID3/READID + data 0x90                 -> READID
- NORMAL/AMDID3/READID + 0xAA @addr&0xFFF==0x555   -> AMDID1
- AMDID1 + 0x55 @0x2AA                             -> AMDID2   (else -> NORMAL)
- AMDID2 @0x555: 0x90 -> AMDID3 | 0x80 -> ERASEAMD1 | 0xA0 -> BYTEPROGRAM
                | 0xF0 -> NORMAL                    (else -> NORMAL)
- ERASEAMD1 + 0xAA @0x555                          -> ERASEAMD2
- ERASEAMD2 + 0x55 @0x2AA                          -> ERASEAMD3
- ERASEAMD3 + 0x10 @0x555 -> CHIP ERASE  (whole 2MB lane of the pair)
- ERASEAMD3 + 0x30 @any   -> SECTOR ERASE (64KB: chip_addr & ~0xFFFF)
  both erase forms: array fill 0xFF NOW, status := 0x08, state -> ERASING
- BYTEPROGRAM + write(addr,data) -> array[addr] &= data (AND semantics), -> NORMAL
- Unknown byte in a command state: MAME logs + leaves mode unchanged (NORMAL-family)
  or falls to NORMAL (AMDID1/2 mismatch). Mirror exactly.

Reads by mode (read_full), per lane:
- NORMAL: array byte (existing DDR3 path, fix-A stall).
- AMDID3/READID: chip_addr&0xFF==0 -> 0x04, ==1 -> 0xAD, else 0x00.
- ERASING: return status, toggling DQ6|DQ2 each read (status ^= 0x44); DQ7=0.
  29F016A special (intelfsh.cpp:584 Firebeat note): ALL addresses return status
  while erasing — no erase-sector range check for this chip.
  ERASING -> NORMAL when the DDR3 fill completes (MAME uses a 1-16s cosmetic
  timer; our real fill takes ms — software polls DQ7/DQ6-toggle, both correct
  the moment the fill ends).
- Program completes within one bus_exp1_wait stall -> next read already NORMAL
  (MAME programs instantly; our RMW hides behind the existing fix-A stall).

## DDR3 side (psx_top memFlash FSM — new write leg)
Existing: ioctl download writes (BE per 16-bit lane) + runtime line reads.
Add two ops, requested from konami573 over a LEVEL req/done 4-phase handshake
(clk1x ce -> clk2x; pulses banned per the flash_dl_done lesson):
- PROG(word_addr, data8, lane): read 64-bit line, AND the target byte
  (lane lo = BE bits {0,2,4,6}, hi = {1,3,5,7}; word lane select = addr(1:0)),
  write back with single-byte BE. (Two independent PROGs for a 16-bit program —
  one per lane FSM; flash software polls between programs, rate is a non-issue.)
- FILL(base_word, len_words, lane): stream 0xFF line writes with lane BE mask
  (0x55/0xAA), 4 words/line. Sector = 64K words ≈ 16K lines ≈ ~2-3 ms;
  chip erase = 2M words ≈ ~40-60 ms. Busy = ERASING status window.
While an op is pending, flash-window READS return status/stall (bus_exp1_wait
reused — level compare, CDC-safe); new data-port writes during busy are queued
1-deep per lane (flash software never back-to-backs without polling).

## What does NOT change
- FA glue semantics (reads increment, writes don't; offset 8 FA|=1; regs 2/4/6
  byte-reassembly). All konamigv.cpp-verified and hardware-proven.
- The flash .bin file on SD stays read-only this phase — writes live in DDR3
  only (in-session). Phase 2 (separate): dirty-flag save-back for high-score
  persistence, modeled on the EEPROM save path.
- EEPROM, SCSI, trackball, IRQ10 — untouched.

## Verification plan (NVC, before any build)
Extend sim/tb_flash.vhd (real konami573 + memorymux + real memFlash FSM + DDR3
model with write support):
1. Regression: existing tight-loop reads still stale-free (fix A intact).
2. ID: FA=0x555 w 0xAA / FA=0x2AA w 0x55 / FA=0x555 w 0x90 -> read FA=0 =>
   0x0404, FA=1 => 0xADAD; 0xF0 resets; reads increment FA throughout.
3. Program: unlock,unlock,0xA0, then write 0x1234 @FA=0x1000 over pre-loaded
   0xFFFF -> readback 0x1234; AND semantics: program 0x00FF over 0x1234 -> 0x0034.
4. Sector erase: unlock×5 + 0x30 @FA in sector -> immediate reads show DQ6
   toggle + DQ7=0 on BOTH lanes; poll until status clears; readback 0xFFFF
   across the sector; word OUTSIDE the 64KB sector unchanged.
5. Chip erase (shortened generic for sim): fill completes, lane isolation held
   (hi-lane content survives a lo-lane chip erase).
6. Byte-lane independence: lo-only command sequence leaves hi FSM in NORMAL
   (hi read returns array while lo returns ID).
7. tb_konami573_boot 26/26 + tb_memmux regression (no EXP1 semantics drift).

## Risks / open items (calibrated)
- The game's actual TEST flash-check sequence is UNKNOWN (probe ring too shallow
  to capture it). The FSM implements MAME's full 29F016A subset, so any sequence
  MAME satisfies, we satisfy — risk is a konamigv glue nuance, not chip protocol
  (~15% residual something else also gates the check screen).
- DDR3 write contention with gameplay streams: ops are rare (TEST mode only),
  FILL bursts ~ms — same arbiter class as the boot download. Low risk; sim
  covers handshake, hardware covers contention.
- ALM cost: 2 small FSMs + op queue + fill counter — est. +200-400 ALMs on a
  98%-full device; seed 9 may need re-sweeping (plan for it).
