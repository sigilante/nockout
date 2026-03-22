#!/usr/bin/env python3
"""
mkpill.py — build a Trinitite PILL v2 binary from a jammed kernel gate.

Usage:
    python3 tools/mkpill.py -n <decimal-atom> <shape> <output.bin>
    python3 tools/mkpill.py <jam-file>         <shape> <output.bin>

Arguments:
    -n <decimal>  Jam atom as a decimal integer (paste directly from Dojo output,
                  dots as thousands separators are stripped automatically).
    jam-file      Raw jam bytes from Urbit (binary file).
    shape         Kernel shape: 'arvo' (0) or 'shrine' (1)
    output.bin    Output PILL v2 file

PILL v2 format:
    bytes  0-7:   uint64_t LE = byte count of jam data
    byte   8:     kernel shape (0=Arvo, 1=Shrine)
    bytes  9-15:  reserved/padding (zeros)
    bytes  16+:   raw jam bytes (little-endian atom, no leading zero bytes)
"""

import sys
import struct

SHAPES = {'arvo': 0, 'shrine': 1}


def atom_to_bytes(n: int) -> bytes:
    """Convert a non-negative integer to little-endian bytes (no leading zeros)."""
    if n == 0:
        return b'\x00'
    out = []
    while n:
        out.append(n & 0xFF)
        n >>= 8
    return bytes(out)


def build_pill(jam_data: bytes, shape_byte: int) -> bytes:
    nbytes = len(jam_data)
    header = struct.pack('<Q', nbytes)   # bytes 0-7: LE length
    header += bytes([shape_byte])        # byte 8: shape
    header += bytes(7)                   # bytes 9-15: padding
    return header + jam_data


def main():
    args = sys.argv[1:]

    if len(args) == 4 and args[0] == '-n':
        # Decimal atom mode: strip Urbit dot-separators then parse
        decimal_str = args[1].replace('.', '').replace(',', '').strip()
        try:
            atom = int(decimal_str)
        except ValueError:
            print(f"error: not a valid integer: {args[1]!r}", file=sys.stderr)
            sys.exit(1)
        jam_data = atom_to_bytes(atom)
        shape_arg, out_file = args[2], args[3]

    elif len(args) == 3:
        jam_file, shape_arg, out_file = args
        with open(jam_file, 'rb') as f:
            jam_data = f.read()
        if not jam_data:
            print("error: jam file is empty", file=sys.stderr)
            sys.exit(1)

    else:
        print(__doc__)
        sys.exit(1)

    if shape_arg not in SHAPES:
        print(f"error: shape must be 'arvo' or 'shrine', got {shape_arg!r}", file=sys.stderr)
        sys.exit(1)

    pill = build_pill(jam_data, SHAPES[shape_arg])

    with open(out_file, 'wb') as f:
        f.write(pill)

    print(f"wrote {len(pill)} bytes to {out_file!r} "
          f"(shape={shape_arg}, jam={len(jam_data)} bytes)")


if __name__ == '__main__':
    main()
