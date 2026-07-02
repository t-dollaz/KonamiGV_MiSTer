#!/usr/bin/env bash
# =============================================================================
# NVC full-system sim for the Konami GV (Baby Phoenix) fork of PSX_MiSTer.
#
# Usage:
#   GV_BIOS_SRC=/path/to/bios.u23 sim/konamigv/run_gv.sh [STOP_TIME]
#     STOP_TIME : NVC --stop-time value (default 5ms)
#
# Key difference from the fabricore 573 harness (sim/system573/run.sh):
#   * No psx_patches to apply — GV RTL (including i-cache fixes 0004/0005
#     and konami573.vhd) is already integrated in our rtl/ directory.
#   * No EXP1 responder — konami573 is inside psx_top; the testbench has no
#     EXP1 ports to drive. Just BIOS + SDRAM + DDRRAM.
#   * GV BIOS from GV_BIOS_SRC (set this to your bios.u23 from the MAME ROM set).
#
# Outputs in build/:
#   pc_trace.log      — non-sequential PC jumps; confirms i-cache fix advances boot
#   bios_fetch.log    — SDRAM reads in BIOS region (0x800000+); confirms CPU is fetching
#   gra_fb_out_vga.gra — video-out capture; convert with tools/gra2png.py
#
# Reading the results:
#   grep "0x1FC" build/pc_trace.log   — PC in BIOS ROM (normal boot phase)
#   grep -v "0x1FC" build/pc_trace.log | head  — first jump into RAM (past copy)
#   wc -l build/bios_fetch.log         — sanity: non-zero = CPU fetching BIOS
#
# REUSE=1: skip patch/analyze/elaborate and re-run the cached design.
#   REUSE=1 GV_BIOS_SRC=... sim/konamigv/run_gv.sh 20ms
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$ROOT/rtl"
MEMSRC="$ROOT/sim/system/src/mem"
TBSRC="$ROOT/sim/system/src/tb"
FABRICORE_NVC="$ROOT/../fabricore-573/sim/nvc"

WD="$HERE/build"
STOP_TIME="${1:-5ms}"
TURBO="${TURBO:-1}"
SLOWVRAM="${SLOWVRAM:-0}"
REUSE="${REUSE:-0}"

# The GV BIOS ROM — 999a01.7e, 512KB, the file loaded on the MiSTer as boot.rom.
# Override with GV_BIOS_SRC=/other/path if needed.
GV_BIOS_SRC="${GV_BIOS_SRC:-$ROOT/../deploy/999a01.7e}"

command -v nvc >/dev/null 2>&1 || {
  echo "error: nvc not found — install with:" >&2
  echo "  sudo dpkg -i /tmp/nvc_1.21.1-1_amd64_ubuntu-26.04.deb" >&2
  exit 1; }

[ -f "$RTL/psx_mister.vhd" ] || {
  echo "error: RTL not found at $RTL" >&2; exit 1; }

[ -f "$FABRICORE_NVC/altera_mf_stub.vhd" ] || {
  echo "error: altera_mf_stub.vhd not found at $FABRICORE_NVC" >&2
  echo "  This stub lives in the fabricore-573 clone at n573-research/fabricore-573/sim/nvc/" >&2
  exit 1; }

NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
# -M / -H: sdram_model3x and ddrram_model declare ~GB-sized process arrays
NVC_MEM="-M 3g -H 6g"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }

if [ "$REUSE" = "1" ]; then
  [ -f "$WD/tb/TB.TB_KONAMIGV.elab" ] || {
    echo "error: REUSE=1 but no elaborated design in $WD; run once without REUSE" >&2; exit 1; }
  echo "== REUSE=1: skipping analyze/elaborate; reusing $WD =="
else

  if [ -z "$GV_BIOS_SRC" ]; then
    echo "error: GV_BIOS_SRC not set and default not found." >&2
    echo "  Expected: \$ROOT/../deploy/999a01.7e (the GV BIOS used on the MiSTer)" >&2
    echo "  Override: GV_BIOS_SRC=/path/to/gv_bios $0" >&2
    exit 1
  fi
  [ -f "$GV_BIOS_SRC" ] || { echo "error: GV_BIOS_SRC not found: $GV_BIOS_SRC" >&2; exit 1; }

  rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"

  # Place BIOS as gv_bios.bin — this is what tb_konamigv.vhd loads via COMMAND_FILE
  cp "$GV_BIOS_SRC" "$WD/gv_bios.bin"
  echo "GV BIOS: $GV_BIOS_SRC -> $WD/gv_bios.bin ($(wc -c < "$WD/gv_bios.bin") bytes)"

  echo "== analyzing altera_mf stub =="
  analyze altera_mf "$FABRICORE_NVC/altera_mf_stub.vhd"

  echo "== analyzing mem library =="
  # Use dpram/RamMLAB from sim/mem, SyncFifo* from rtl/ (mirrors fabricore run.sh pattern)
  analyze mem \
      "$MEMSRC/dpram.vhd" \
      "$MEMSRC/RamMLAB.vhd" \
      "$RTL/SyncFifo.vhd" \
      "$RTL/SyncFifoFallThrough.vhd" \
      "$RTL/SyncFifoFallThroughMLAB.vhd" \
      "$RTL/SyncRam.vhd" \
      "$RTL/SyncRamDual.vhd" \
      "$RTL/SyncRamDualNotPow2.vhd"

  echo "== analyzing psx core library =="
  # Compile order mirrors the fabricore run.sh (upstream dependency order).
  # konami573 added before psx_top since psx_top instantiates it.
  analyze psx "$MEMSRC/dpram.vhd"
  CORE=(export divider pGPU mul32u mul9s gpu_fillVram gpu_cpu2vram gpu_vram2vram \
    gpu_vram2cpu gpu_line gpu_rect gpu_poly gpu_pixelpipeline gpu_overlay gpu_dither \
    gpu_videoout_async gpu_videoout_sync gpu_crosshair justifier_sensor gpu_videoout gpu \
    irq pJoypad joypad_pad joypad_mem joypad timer dma exp2 pGTE gte_mac0 gte_mac123 \
    gte_UNRDivide gte mdec cd_xa_zigzag cd_xa cd_top memctrl sio spu_ram spu_gauss spu \
    datacache cpu memorymux memcard statemanager savestates cheats konami573 psx_top psx_mister)
  files=(); for f in "${CORE[@]}"; do files+=("$RTL/$f.vhd"); done
  analyze psx "${files[@]}"

  echo "== analyzing tb library (memory models + tb_konamigv) =="
  analyze tb \
      "$TBSRC/globals.vhd" \
      "$TBSRC/sdram_model3x.vhd" \
      "$TBSRC/ddrram_model.vhd" \
      "$TBSRC/framebuffer.vhd"
  analyze tb "$HERE/tb_konamigv.vhd"

  echo "== elaborating tb_konamigv (TURBO=$TURBO SLOWVRAM=$SLOWVRAM) =="
  $NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_konamigv --stats \
       -gTURBO="'$TURBO'" -gSLOWVRAM="$SLOWVRAM"

fi  # end REUSE=0

echo "== running tb_konamigv (stop-time=$STOP_TIME) =="
cd "$WD"
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_konamigv \
     --stats --stop-time="$STOP_TIME"

echo
echo "== outputs in $WD =="
ls -la "$WD"/*.gra "$WD"/*.log 2>/dev/null || true
echo
echo "== PC summary =="
echo "  BIOS fetches: $(wc -l < "$WD/bios_fetch.log" 2>/dev/null || echo 0)"
echo "  PC jumps:     $(wc -l < "$WD/pc_trace.log" 2>/dev/null || echo 0)"
echo "  First PC:     $(head -1 "$WD/pc_trace.log" 2>/dev/null || echo '(empty)')"
echo "  Last PC:      $(tail -1 "$WD/pc_trace.log" 2>/dev/null || echo '(empty)')"
echo
echo "  If PC is advancing through 0x1FC0xxxx = CPU running BIOS code (good)."
echo "  If PC eventually shows 0x8xxxxxxx  = CPU reached game RAM (boot advanced)."
