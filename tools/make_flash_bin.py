#!/usr/bin/env python3
"""Build the 8 MB Simpsons Bowling flash image this core expects.

The Konami GV "Baby Phoenix" board carries 4x Fujitsu 29F016A (2 MB each).
The core consumes ONE 8 MB file with the chips byte-interleaved in pairs:

    out[0::2] = flash0    out[1::2] = flash1     (first 4 MB)
    then flash2/flash3 the same way              (second 4 MB)

Usage:  python3 make_flash_bin.py flash0 flash1 flash2 flash3 out.bin

Verified against the known-working image:
    sha1(out) = 2a44760ff2865a6d1690033d12925c31102a0d77
when built from the Arcade1Up Simpsons Bowling flash0..flash3 dumps.
A plain concatenation, or any other chip order, will NOT boot
(symptom: "FREEPLAY" over a black screen - the game code never loads).
"""
import sys, hashlib

GOLDEN_SHA1 = "2a44760ff2865a6d1690033d12925c31102a0d77"

def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    chips = []
    for p in sys.argv[1:5]:
        d = open(p, "rb").read()
        if len(d) != 2 * 1024 * 1024:
            sys.exit(f"{p}: expected 2097152 bytes (a 29F016A dump), got {len(d)}")
        chips.append(d)
    def weave(a, b):
        out = bytearray(len(a) * 2)
        out[0::2] = a
        out[1::2] = b
        return bytes(out)
    img = weave(chips[0], chips[1]) + weave(chips[2], chips[3])
    open(sys.argv[5], "wb").write(img)
    h = hashlib.sha1(img).hexdigest()
    mark = "MATCHES the known-working image" if h == GOLDEN_SHA1 else \
           "does not match the reference (different source dumps?)"
    print(f"wrote {sys.argv[5]}  sha1={h}\n{mark}")

if __name__ == "__main__":
    main()
