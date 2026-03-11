#!/usr/bin/env python3
"""
tools/jam.py — Nock noun serialization (jam) and deserialization (cue).

Stdlib only; no external dependencies.

Usage:
    python3 tools/jam.py jam  NOUN   # encode noun atom, print decimal
    python3 tools/jam.py cue  ATOM   # decode atom, print noun
    python3 tools/jam.py test        # run self-tests

NOUN syntax:  integers and brackets, dot-separators in atoms are ignored.
    Examples:  42
               [1 2 3]
               [11 [[1735355507 [0 6]] [[1 0] [0 1]]]]

ATOM:  decimal integer (dot-separators stripped automatically).

Nouns are represented internally as int (atom) or (head, tail) tuple (cell).
"""

import sys


# ── Noun helpers ──────────────────────────────────────────────────────────────

def deep(n):
    return isinstance(n, tuple)


def noun_str(n, tail=False):
    if not deep(n):
        return str(n)
    content = noun_str(n[0], False) + ' ' + noun_str(n[1], True)
    return content if tail else '[' + content + ']'


# ── mat / rub (self-describing integer encoding) ──────────────────────────────

def _mat_bits(i):
    """Return list of bits for mat(i), LSB first."""
    if i == 0:
        return [1]
    a = i.bit_length()      # bits needed for i
    b = a.bit_length()      # bits needed for a
    above, below = b + 1, b - 1
    bits = []
    v = 1 << b
    for k in range(above):                  bits.append((v >> k) & 1)
    mask = (1 << below) - 1 if below > 0 else 0
    for k in range(below):                  bits.append(((a & mask) >> k) & 1)
    for k in range(a):                      bits.append((i >> k) & 1)
    return bits


# ── jam: noun → atom ──────────────────────────────────────────────────────────

def jam(noun):
    """Encode a noun as an integer atom (Urbit jam serialization)."""
    buf  = []
    refs = {}   # ('a', value) for atoms, id(cell) for cells → bit position

    def back(pos):
        buf.append(1); buf.append(1)
        buf.extend(_mat_bits(pos))

    def encode(n):
        pos = len(buf)
        if deep(n):
            key = id(n)
            if key in refs:
                back(refs[key]); return
            refs[key] = pos
            buf.append(1); buf.append(0)        # tag 01 = cell
            encode(n[0]); encode(n[1])
        else:
            key = ('a', n)
            if key in refs:
                dupe = refs[key]
                # choose shorter: direct atom encoding vs back-reference
                if n.bit_length() < dupe.bit_length():
                    refs[key] = pos
                    buf.append(0); buf.extend(_mat_bits(n))
                else:
                    back(dupe)
                return
            refs[key] = pos
            buf.append(0)                        # tag 0 = atom
            buf.extend(_mat_bits(n))

    encode(noun)
    result = 0
    for i, b in enumerate(buf):
        if b:
            result |= 1 << i
    return result


# ── cue: atom → noun ──────────────────────────────────────────────────────────

def cue(atom):
    """Decode an integer atom back to a noun (Urbit cue deserialization)."""
    refs = {}
    pos  = [0]

    def bit():
        b = (atom >> pos[0]) & 1
        pos[0] += 1
        return b

    def rub():
        """Read a mat-encoded integer."""
        z = 0
        while not bit():
            z += 1
        if z == 0:
            return 0
        lbits = 0
        for i in range(z - 1):
            lbits |= bit() << i
        k = (1 << (z - 1)) ^ lbits
        v = 0
        for i in range(k):
            v |= bit() << i
        return v

    def decode():
        start = pos[0]
        if bit():
            if bit():               # tag 11 = back-reference
                r = refs[rub()]
            else:                   # tag 01 = cell
                h = decode()
                t = decode()
                r = (h, t)
        else:                       # tag 0 = atom
            r = rub()
        refs[start] = r
        return r

    return decode()


# ── noun parser ───────────────────────────────────────────────────────────────

def parse(s):
    """Parse a noun from string notation: integers and [head tail ...] cells."""
    s = s.replace('.', '')     # strip Urbit dot-separators in numbers
    tokens = s.replace('[', ' [ ').replace(']', ' ] ').split()

    idx = [0]

    def read():
        tok = tokens[idx[0]]; idx[0] += 1
        if tok == '[':
            items = []
            while tokens[idx[0]] != ']':
                items.append(read())
            idx[0] += 1  # consume ']'
            if len(items) < 2:
                raise ValueError('cell needs at least 2 elements')
            # right-fold: [a b c] → (a, (b, c))
            result = items[-1]
            for item in reversed(items[:-1]):
                result = (item, result)
            return result
        else:
            return int(tok)

    result = read()
    if idx[0] != len(tokens):
        raise ValueError(f'unexpected tokens after noun: {tokens[idx[0]:]}')
    return result


# ── self-tests ────────────────────────────────────────────────────────────────

def _run_tests():
    ok = True

    def check(label, got, expected):
        nonlocal ok
        if got != expected:
            print(f'FAIL  {label}: got {got!r}, expected {expected!r}')
            ok = False
        else:
            print(f'PASS  {label}')

    # jam canonical values (from pynoun doctests)
    check('jam(0)',          jam(0),      2)
    check('jam([0 0])',      jam((0, 0)), 41)

    # round-trips
    for n in [0, 1, 42, 255, 2**32, (0, 0), (1, (2, 3)), ((1, 2), (3, 4))]:
        check(f'cue(jam({noun_str(n)}))', cue(jam(n)), n)

    # parser
    check('parse 42',        parse('42'),        42)
    check('parse [1 2 3]',   parse('[1 2 3]'),   (1, (2, 3)))
    check('parse 1.024',     parse('1.024'),      1024)

    # known kernel atoms
    SLOG = 0x676F6C73
    hint_arvo   = ((11, ((SLOG, (0, 6)), ((1, 0), (0, 1)))),            (0, 0))
    null_shrine = (((1, 0), ((0, 1), (1, 0))),                           (0, 0))
    hint_shrine = ((11, ((SLOG, (0, 6)), ((1, 0), ((0, 1), (1, 0))))),  (0, 0))

    check('hint-arvo  round-trip', cue(jam(hint_arvo)),   hint_arvo)
    check('null-shrine round-trip', cue(jam(null_shrine)), null_shrine)
    check('hint-shrine round-trip', cue(jam(hint_shrine)), hint_shrine)

    # null-arvo atom from Dojo (pre-computed)
    NULL_ARVO = 3533463315829630395733151849237
    decoded = cue(NULL_ARVO)
    if not deep(decoded):
        print('FAIL  null-arvo atom decodes to a cell'); ok = False
    else:
        print('PASS  null-arvo atom decodes to a cell')

    return ok


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); sys.exit(0)

    cmd = args[0]

    if cmd == 'jam':
        if len(args) != 2:
            print('usage: jam.py jam NOUN', file=sys.stderr); sys.exit(1)
        print(jam(parse(args[1])))

    elif cmd == 'cue':
        if len(args) != 2:
            print('usage: jam.py cue ATOM', file=sys.stderr); sys.exit(1)
        atom = int(args[1].replace('.', '').replace(',', ''))
        print(noun_str(cue(atom)))

    elif cmd == 'test':
        ok = _run_tests()
        sys.exit(0 if ok else 1)

    else:
        print(f'unknown command: {cmd!r}', file=sys.stderr)
        print(__doc__); sys.exit(1)


if __name__ == '__main__':
    main()
