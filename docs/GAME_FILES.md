# Simpsons Bowling on MiSTer — game file setup

The core rbf is prebuilt in [`releases/`](../releases/) (`KonamiGV_YYYYMMDD.rbf`).
Everything else is game data you must supply. **No game data is distributed
here** — this page tells you exactly what the files are, how to prepare them,
and the sha1 of every known-working file so you can verify yours.

## What the core loads

| MGL slot | File | Size | Purpose |
|---|---|---|---|
| (implicit) | `boot.rom` | 512 KB | Konami GV BIOS `999a01.7e` |
| S0, index 0 | EEPROM image | 128 B | operator settings + security word |
| F2, index 2 | flash image | 8 MB | game program/data (4× 29F016A, interleaved) |
| S4, index 4 | disc image | ~48 MB | the game CD, 2048-byte-sector ISO |

## Known-working hashes (sha1)

| File | sha1 |
|---|---|
| `boot.rom` (999a01.7e, MAME `konamigv` set) | `02a82a2fe1fba0404517c3602324bfa64e23e478` |
| flash image (built per below) | `2a44760ff2865a6d1690033d12925c31102a0d77` |
| disc ISO (Arcade1Up rip) | `448af5f4005ac566d0d5b107510b6237aad686d7` |

Any other flash image — including a plain concatenation of the four chips, or
repacks circulating with other file sets (e.g. sha1 `d3aae2a7…`) — will not
boot: the classic symptom is **"FREEPLAY" over a black screen** (the game
program never loads from flash).

## Building the flash image

The four 2 MB chip dumps (`flash0`..`flash3` from an Arcade1Up cabinet, or
equivalent 29F016A dumps) must be byte-interleaved in pairs. Use the included
script — it verifies the result hash for you:

```
python3 tools/make_flash_bin.py flash0 flash1 flash2 flash3 flash_573_simpbowl.bin
```

## The EEPROM

The 128-byte EEPROM holds operator settings (coinage/freeplay) and the
security word the game checks at boot. Sources, in order of preference:

1. A working EEPROM image from a real cabinet or the MAME `simpbowl` set
   (`eeprom-simpbowl.25c`).
2. Once flash writes are fully validated in this core, the game's own
   Service-Mode initialization can generate one from scratch (boot with
   OSD → Service Mode ON from a clean reset).

Whatever you use, the file just needs to be named per the layout below. The
core auto-saves it, so settings persist.

## Layout A — this repo's MGL (recommended)

Files (copy `mgl/Simpsons Bowling.mgl` to `/media/fat/`):

```
/media/fat/SimpsonsBowling.rbf              (rename the releases/ rbf, or
                                             keep KonamiGV_*.rbf and edit the
                                             MGL's <rbf> tag to match)
/media/fat/games/PSX/boot.rom
/media/fat/games/PSX/arcade.iso             (the disc ISO)
/media/fat/games/PSX/573/simpbowl.sav       (the EEPROM)
/media/fat/games/PSX/573/flash_573_simpbowl.bin
```

## Layout B — "KonamiGV" setname layout (unofficial-distro style)

If your MGL contains `<setname>KonamiGV</setname>`, the core's name changes
to KonamiGV and **`boot.rom` is looked up in `games/KonamiGV/` instead**:

```
/media/fat/games/KonamiGV/boot.rom
/media/fat/games/KonamiGV/simpbowl.iso      (the disc ISO)
/media/fat/games/KonamiGV/simpbowl.25c      (the EEPROM)
/media/fat/games/KonamiGV/simpbowl_flash.bin
```

with an MGL like:

```xml
<mistergamedescription>
    <rbf>_Arcade/KonamiGV</rbf>   <!-- wherever the rbf lives, no extension -->
    <setname>KonamiGV</setname>
    <file delay="1" type="s" index="0" path="/media/fat/games/KonamiGV/simpbowl.25c"/>
    <file delay="2" type="f" index="2" path="/media/fat/games/KonamiGV/simpbowl_flash.bin"/>
    <file delay="3" type="s" index="4" path="/media/fat/games/KonamiGV/simpbowl.iso"/>
</mistergamedescription>
```

The two layouts are functionally identical — only names/paths differ. The
slot structure (S0 / F2 / S4 with delays 1/2/3) must not be changed.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "FREEPLAY" over black screen, nothing else | wrong flash image (bad interleave / wrong content) — rebuild with `tools/make_flash_bin.py` and check the sha1 |
| SECURITY CODE ERROR at boot | EEPROM invalid/corrupt — restore a known-good image |
| Boots to PS1 BIOS instead of the game | `boot.rom` missing or in the wrong folder for your layout (see setname note above) |
| Black screen after "PLEASE WAIT" | see README Service-Mode notes |
