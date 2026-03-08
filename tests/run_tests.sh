#!/usr/bin/env bash
# Fock regression test suite — Nock opcodes 0-11 + SLOT
# Usage: ./tests/run_tests.sh [--verbose]
#
# Each test feeds one Forth expression to the REPL and checks the hex
# output value.  All tests run in a single QEMU session for speed.

set -euo pipefail
cd "$(dirname "$0")/.."

VERBOSE=0
[[ "${1-}" == "--verbose" ]] && VERBOSE=1

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0

# ── Test registry ──────────────────────────────────────────────────────────
# Parallel arrays: TNAMES[], TEXPECT[], TLINES[]
TNAMES=()
TEXPECT=()
TLINES=()

T() {   # T  "description"  "expected-hex-uppercase-16"  "forth expression"
    TNAMES+=("$1")
    TEXPECT+=("hex:$2")
    TLINES+=("$3")
}

TD() {  # TD "description"  "expected-decimal-string"  "forth expression"
    TNAMES+=("$1")
    TEXPECT+=("dec:$2")
    TLINES+=("$3")
}

# ── Preamble (defines helpers, produces no numeric output) ─────────────────
PREAMBLE=': N>N >NOUN ;
: C>N N>N SWAP N>N SWAP CONS ;
: JCORE1 0 N>N CONS 0 N>N SWAP CONS ;
: JCORE2 CONS 0 N>N CONS 0 N>N SWAP CONS ;
: JD 1 N>N SWAP CONS 2 N>N SWAP CONS 9 N>N SWAP CONS ;
: JWRAP SWAP 1 N>N 0 N>N CONS CONS 0 N>N CONS 1 N>N SWAP CONS 1684826487 N>N SWAP CONS SWAP CONS 11 N>N SWAP CONS ;'

# ── Slot / op 0 ────────────────────────────────────────────────────────────
# SLOT word direct
T "SLOT axis 1 (root atom)"     "000000000000002A" "1 N>N  42 N>N  SLOT NOUN> ."
T "SLOT axis 2 (head)"          "0000000000000001" "2 N>N  1 2 C>N  SLOT NOUN> ."
T "SLOT axis 3 (tail)"          "0000000000000002" "3 N>N  1 2 C>N  SLOT NOUN> ."
T "SLOT axis 4 (head.head)"     "0000000000000001" "4 N>N  1 2 C>N  3 4 C>N CONS  SLOT NOUN> ."
T "SLOT axis 5 (tail.head)"     "0000000000000002" "5 N>N  1 2 C>N  3 4 C>N CONS  SLOT NOUN> ."
T "SLOT axis 6 (head.tail)"     "0000000000000003" "6 N>N  1 2 C>N  3 4 C>N CONS  SLOT NOUN> ."
T "SLOT axis 7 (tail.tail)"     "0000000000000004" "7 N>N  1 2 C>N  3 4 C>N CONS  SLOT NOUN> ."

# Via NOCK op 0
T "op0: *[42 [0 1]] = 42"       "000000000000002A" \
    "42 N>N  0 N>N 1 N>N CONS  NOCK NOUN> ."
T "op0: *[[1 2] [0 2]] = 1"     "0000000000000001" \
    "1 2 C>N  0 N>N 2 N>N CONS  NOCK NOUN> ."
T "op0: *[[1 2] [0 3]] = 2"     "0000000000000002" \
    "1 2 C>N  0 N>N 3 N>N CONS  NOCK NOUN> ."
T "op0: axis 4 (head.head)"     "0000000000000001" \
    "1 2 C>N  3 4 C>N CONS  0 N>N 4 N>N CONS  NOCK NOUN> ."
T "op0: axis 5 (tail.head)"     "0000000000000002" \
    "1 2 C>N  3 4 C>N CONS  0 N>N 5 N>N CONS  NOCK NOUN> ."
T "op0: axis 6 (head.tail)"     "0000000000000003" \
    "1 2 C>N  3 4 C>N CONS  0 N>N 6 N>N CONS  NOCK NOUN> ."
T "op0: axis 7 (tail.tail)"     "0000000000000004" \
    "1 2 C>N  3 4 C>N CONS  0 N>N 7 N>N CONS  NOCK NOUN> ."

# ── Op 1: quote ────────────────────────────────────────────────────────────
T "op1: *[_ [1 42]] = 42"       "000000000000002A" \
    "0 N>N  1 N>N 42 N>N CONS  NOCK NOUN> ."
T "op1: *[_ [1 0]] = 0"         "0000000000000000" \
    "0 N>N  1 N>N 0 N>N CONS  NOCK NOUN> ."
T "op1: quoted cell head = 1"   "0000000000000001" \
    "0 N>N  1 N>N 1 2 C>N CONS  NOCK CAR NOUN> ."
T "op1: quoted cell tail = 2"   "0000000000000002" \
    "0 N>N  1 N>N 1 2 C>N CONS  NOCK CDR NOUN> ."

# ── Op 2: compose/eval (TCO) ───────────────────────────────────────────────
# *[99 [2 [1 42] [1 [0 1]]]] = *[42 [0 1]] = 42
T "op2: compose atom result"    "000000000000002A" \
    "99 N>N  2 N>N  1 N>N 42 N>N CONS  1 N>N 0 N>N 1 N>N CONS CONS  CONS  CONS  NOCK NOUN> ."
# *[_ [2 [1 5] [1 [4 [0 1]]]]] = *[5 [4 [0 1]]] = +5 = 6
T "op2: compose then lus"       "0000000000000006" \
    "0 N>N  2 N>N  1 N>N 5 N>N CONS  1 N>N 4 N>N 0 N>N 1 N>N CONS CONS CONS  CONS  CONS  NOCK NOUN> ."

# ── Op 3: wut (is cell?) ───────────────────────────────────────────────────
T "op3: ?atom = 1 (no)"         "0000000000000001" \
    "42 N>N  3 N>N  0 N>N 1 N>N CONS  CONS  NOCK NOUN> ."
T "op3: ?cell = 0 (yes)"        "0000000000000000" \
    "1 2 C>N  3 N>N  0 N>N 1 N>N CONS  CONS  NOCK NOUN> ."
T "op3: ?quoted-cell = 0"       "0000000000000000" \
    "0 N>N  3 N>N  1 N>N 1 2 C>N CONS  CONS  NOCK NOUN> ."

# ── Op 4: lus (increment atom) ─────────────────────────────────────────────
T "op4: +0 = 1"                 "0000000000000001" \
    "0 N>N  4 N>N  0 N>N 1 N>N CONS  CONS  NOCK NOUN> ."
T "op4: +100 = 101"             "0000000000000065" \
    "100 N>N  4 N>N  0 N>N 1 N>N CONS  CONS  NOCK NOUN> ."
T "op4: +255 = 256"             "0000000000000100" \
    "255 N>N  4 N>N  0 N>N 1 N>N CONS  CONS  NOCK NOUN> ."

# ── Op 5: tis (equality) ───────────────────────────────────────────────────
T "op5: =[42 42] = 0 (yes)"     "0000000000000000" \
    "42 N>N  5 N>N  0 N>N 1 N>N CONS  0 N>N 1 N>N CONS  CONS CONS  NOCK NOUN> ."
T "op5: =[1 2] = 1 (no)"        "0000000000000001" \
    "1 2 C>N  5 N>N  0 N>N 2 N>N CONS  0 N>N 3 N>N CONS  CONS CONS  NOCK NOUN> ."
# =[43 +42] = =[43 43] = 0 (yes)
T "op5: =[43 +42] = 0 (yes)"   "0000000000000000" \
    "42 N>N  5 N>N  1 N>N 43 N>N CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# =[99 +42] = =[99 43] = 1 (no)
T "op5: =[99 +42] = 1 (no)"    "0000000000000001" \
    "42 N>N  5 N>N  1 N>N 99 N>N CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."

# ── Distribution rule (autocons) ───────────────────────────────────────────
# *[42 [[0 1] [4 [0 1]]]] = [42 43]
T "distrib: head = 42"          "000000000000002A" \
    "42 N>N  0 N>N 1 N>N CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS  NOCK CAR NOUN> ."
T "distrib: tail = 43"          "000000000000002B" \
    "42 N>N  0 N>N 1 N>N CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS  NOCK CDR NOUN> ."
# *[_ [[1 7] [1 8]]] = [7 8]
T "distrib: two constants"      "0000000000000007" \
    "0 N>N  1 N>N 7 N>N CONS  1 N>N 8 N>N CONS  CONS  NOCK CAR NOUN> ."

# ── Op 9: arm invocation ──────────────────────────────────────────────────
# *[0 [9 2 [1 [[4 [0 3]] 42]]]]
#   core = [[4 [0 3]] 42], arm = slot(2,core) = [4 [0 3]]
#   nock(core, [4 [0 3]]) = +slot(3,core) = +42 = 43
T "op9: arm at axis 2"          "000000000000002B" \
    "0 N>N  9 N>N  2 N>N  1 N>N  4 N>N 0 N>N 3 N>N CONS CONS  42 N>N CONS  CONS  CONS  CONS  NOCK NOUN> ."
# *[0 [9 3 [1 [100 [4 [0 2]]]]]]
#   core = [100 [4 [0 2]]], arm = slot(3,core) = [4 [0 2]]
#   nock(core, [4 [0 2]]) = +slot(2,core) = +100 = 101
T "op9: arm at axis 3"          "0000000000000065" \
    "0 N>N  9 N>N  3 N>N  1 N>N  100 N>N  4 N>N 0 N>N 2 N>N CONS CONS  CONS  CONS  CONS  CONS  NOCK NOUN> ."
# Canonical Hoon pattern: op8 pin arm, op9 call it
# *[10 [8 [1 [4 [0 3]]] [9 2 [0 1]]]]
#   pin [4 [0 3]] -> new_subj = [[4 [0 3]] 10]
#   core = slot(1, new_subj) = [[4 [0 3]] 10]
#   arm  = slot(2, core) = [4 [0 3]]
#   nock(core, [4 [0 3]]) = +slot(3, core) = +10 = 11
T "op9: op8+op9 (Hoon pattern)" "000000000000000B" \
    "10 N>N  8 N>N  1 N>N 4 N>N 0 N>N 3 N>N CONS CONS CONS  9 N>N 2 N>N 0 N>N 1 N>N CONS CONS CONS  CONS CONS  NOCK NOUN> ."

# ── Op 6: if-then-else ────────────────────────────────────────────────────
# condition = quoted YES  →  then-branch
T "op6: YES->then (42)"         "000000000000002A" \
    "0 N>N  6 N>N  1 N>N 0 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  NOCK NOUN> ."
# condition = quoted NO  →  else-branch
T "op6: NO->else (99)"          "0000000000000063" \
    "0 N>N  6 N>N  1 N>N 1 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  NOCK NOUN> ."
# condition from subject (0=YES)
T "op6: subj=YES->then"         "000000000000002A" \
    "0 N>N  6 N>N  0 N>N 1 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  NOCK NOUN> ."
# condition from subject (1=NO)
T "op6: subj=NO->else"          "0000000000000063" \
    "1 N>N  6 N>N  0 N>N 1 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  NOCK NOUN> ."
# branches use subject: YES->lus(5)=6, else->5
T "op6: then-branch uses subj"  "0000000000000006" \
    "5 N>N  6 N>N  1 N>N 0 N>N CONS  4 N>N 0 N>N 1 N>N CONS CONS  0 N>N 1 N>N CONS  CONS CONS CONS  NOCK NOUN> ."

# ── Op 7: compose ─────────────────────────────────────────────────────────
# *[5 [7 [4 [0 1]] [4 [0 1]]]] = *[6 [4 [0 1]]] = 7
T "op7: double lus"             "0000000000000007" \
    "5 N>N  7 N>N  4 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS  CONS  NOCK NOUN> ."
# *[[1 2] [7 [0 2] [4 [0 1]]]] = *[1 [4 [0 1]]] = 2
T "op7: slot then lus"          "0000000000000002" \
    "1 2 C>N  7 N>N  0 N>N 2 N>N CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS  CONS  NOCK NOUN> ."
# *[3 [7 [1 10] [6 [0 1] [1 42] [1 99]]]] = *[10 [6 [0 1] ...]] = else(99)
# 10=NOUN_NO? No, 10 is not a boolean. Use subject 1=NOUN_NO:
# *[_ [7 [1 1] [6 [0 1] [1 42] [1 99]]]] = *[1 [6 [0 1]...]] = 99
T "op7: compose into if"        "0000000000000063" \
    "0 N>N  7 N>N  1 N>N 1 N>N CONS  6 N>N 0 N>N 1 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  CONS  CONS  NOCK NOUN> ."

# ── Op 8: pin ─────────────────────────────────────────────────────────────
# *[42 [8 [1 99] [0 2]]] = *[[99 42] [0 2]] = 99  (pinned value)
T "op8: slot pinned"            "0000000000000063" \
    "42 N>N  8 N>N  1 N>N 99 N>N CONS  0 N>N 2 N>N CONS  CONS CONS  NOCK NOUN> ."
# *[42 [8 [4 [0 1]] [0 2]]] = *[[43 42] [0 2]] = 43  (lus then slot head)
T "op8: pin lus, slot head"     "000000000000002B" \
    "42 N>N  8 N>N  4 N>N 0 N>N 1 N>N CONS CONS  0 N>N 2 N>N CONS  CONS CONS  NOCK NOUN> ."
# *[42 [8 [4 [0 1]] [0 3]]] = *[[43 42] [0 3]] = 42  (old subject preserved)
T "op8: old subj preserved"     "000000000000002A" \
    "42 N>N  8 N>N  4 N>N 0 N>N 1 N>N CONS CONS  0 N>N 3 N>N CONS  CONS CONS  NOCK NOUN> ."
# *[5 [8 [1 42] [5 [0 2] [0 2]]]] = =[99 99]? No:
# *[5 [8 [1 42] [5 [0 2] [0 3]]]] = =[ *[[42 5] [0 2]]  *[[42 5] [0 3]] ] = =[42 5] = 1
T "op8: pin then tis head/tail" "0000000000000001" \
    "5 N>N  8 N>N  1 N>N 42 N>N CONS  5 N>N 0 N>N 2 N>N CONS  0 N>N 3 N>N CONS  CONS CONS  CONS CONS  NOCK NOUN> ."

# ── Op 10: tree edit / static hint ────────────────────────────────────────
# Static hint: *[42 [10 7 [0 1]]] = *[42 [0 1]] = 42  (hint atom 7 discarded)
T "op10: static hint atom"      "000000000000002A" \
    "42 N>N  10 N>N 7 N>N 0 N>N 1 N>N CONS CONS CONS  NOCK NOUN> ."
# Static hint with computation: *[5 [10 99 [4 [0 1]]]] = *[5 [4 [0 1]]] = 6
T "op10: static hint+lus"       "0000000000000006" \
    "5 N>N  10 N>N 99 N>N 4 N>N 0 N>N 1 N>N CONS CONS CONS CONS  NOCK NOUN> ."
# Dynamic: *[[1 2] [10 [2 [1 99]] [0 1]]] = #[2 99 [1 2]] = [99 2]
#   hint=[2 [1 99]]: axis b=2, val=*[subj [1 99]]=99; target=*[subj [0 1]]=[1 2]
#   hax(2, 99, [1 2]) → [99 2]
T "op10: edit axis 2 (head)"    "0000000000000063" \
    "1 2 C>N  10 N>N  2 N>N 1 N>N 99 N>N CONS CONS  0 N>N 1 N>N CONS  CONS  CONS  NOCK CAR NOUN> ."
# Sibling preserved: tail of [99 2] = 2
T "op10: edit axis 2, sibling"  "0000000000000002" \
    "1 2 C>N  10 N>N  2 N>N 1 N>N 99 N>N CONS CONS  0 N>N 1 N>N CONS  CONS  CONS  NOCK CDR NOUN> ."
# Dynamic: *[[1 2] [10 [3 [1 99]] [0 1]]] = #[3 99 [1 2]] = [1 99]
T "op10: edit axis 3 (tail)"    "0000000000000063" \
    "1 2 C>N  10 N>N  3 N>N 1 N>N 99 N>N CONS CONS  0 N>N 1 N>N CONS  CONS  CONS  NOCK CDR NOUN> ."
# Deep: *[[[1 2] 3] [10 [4 [1 99]] [0 1]]] = #[4 99 [[1 2] 3]] = [[99 2] 3]
#   hax(4, 99, [[1 2] 3]): d=2, first=0 (head), sub=2
#   → [hax(2, 99, [1 2])  3] = [[99 2] 3]
T "op10: deep edit axis 4"      "0000000000000063" \
    "1 2 C>N 3 N>N CONS  10 N>N  4 N>N 1 N>N 99 N>N CONS CONS  0 N>N 1 N>N CONS  CONS  CONS  NOCK CAR CAR NOUN> ."

# ── Op 11: hints ──────────────────────────────────────────────────────────
# Static hint: *[42 [11 7 [0 1]]] = *[42 [0 1]] = 42  (atom tag discarded)
T "op11: static hint"           "000000000000002A" \
    "42 N>N  11 N>N 7 N>N 0 N>N 1 N>N CONS CONS CONS  NOCK NOUN> ."
# Static hint with lus: *[5 [11 99 [4 [0 1]]]] = 6
T "op11: static hint+lus"       "0000000000000006" \
    "5 N>N  11 N>N 99 N>N 4 N>N 0 N>N 1 N>N CONS CONS CONS CONS  NOCK NOUN> ."
# Dynamic hint, unrecognized tag: *[42 [11 [42 [0 1]] [4 [0 1]]]] = +42 = 43
# tag=42, clue=slot(1,42)=42, d=[4 [0 1]], result=43
T "op11: dynamic noop hint"     "000000000000002B" \
    "42 N>N  11 N>N  42 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# %slog hint: result is d's value regardless of slog side-effect
# *[7 [11 [%slog [0 1]] [4 [0 1]]]] = 8  (slog prints 7 to UART)
T "op11: %slog returns d"       "0000000000000008" \
    "7 N>N  11 N>N  1735355507 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# %xray hint: result is d's value regardless of xray side-effect
# *[9 [11 [%xray [0 1]] [4 [0 1]]]] = 10  (%xray cord = 2036429432)
T "op11: %xray returns d"       "000000000000000A" \
    "9 N>N  11 N>N  2036429432 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."

# ── Phase 4a: bignum increment and equality ───────────────────────────────
# 2^62-1 = 4611686018427387903 = max direct atom value
# 2^62-2 = 4611686018427387902
#
# inc at direct→indirect boundary: result must be an atom (ATOM? → Forth -1)
T "bn_inc: boundary → atom"     "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK ATOM? ."
# two independent increments of same maxval are noun-equal
T "bn_inc: eq same boundary"    "0000000000000000" \
    "0 N>N  5 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# increments of different values are not equal
T "bn_inc: neq diff boundary"   "0000000000000001" \
    "0 N>N  5 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  4 N>N 1 N>N 4611686018427387902 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# double increment of indirect atom: still an atom
T "bn_inc: indirect → atom"     "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  CONS  NOCK ATOM? ."
# double increment equality: two independent double-incs are equal
T "bn_inc: eq double indirect"  "0000000000000000" \
    "0 N>N  5 N>N  4 N>N 4 N>N 1 N>N 4611686018427387903 N>N CONS CONS CONS  4 N>N 4 N>N 1 N>N 4611686018427387903 N>N CONS CONS CONS  CONS CONS  NOCK NOUN> ."

# ── Phase 4b: BLAKE3 hashing and HATOM word ──────────────────────────────
# Official test vectors (input[i]=i%251, lens 0,1,63,64,65,1024,1025)
T "blake3: official vectors"    "0000000000000001" "B3OK ."
# HATOM on a direct atom is a no-op; still an atom
T "hash_atom: direct is atom"   "FFFFFFFFFFFFFFFF" \
    "42 N>N HATOM ATOM? ."
# HATOM on indirect atom (2^62) still yields an atom
T "hash_atom: indirect is atom" "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM ATOM? ."
# Two independently computed 2^62 atoms hash to identical prefix → =NOUN true
T "hash_atom: equal same value" "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM \
     =NOUN ."
# 2^62 vs 2^62+1 — different values → =NOUN false (0)
T "hash_atom: unequal values"   "0000000000000000" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM \
     0 N>N  4 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS CONS  NOCK HATOM \
     =NOUN ."

# ── Phase 4c: bignum arithmetic and decimal I/O ───────────────────────────
# bn_dec: decrement indirect atom 2^62 → 2^62-1 (direct) → ATOM? true
# Compute 2^62 via Nock op4 on (2^62-1), then BNDEC, check ATOM?
T "bn_dec: indirect→direct"    "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  BNDEC ATOM? ."
# bn_dec of 2^62 → 2^62-1 (direct atom); NOUN> should yield 4611686018427387903
T "bn_dec: value correct"      "3FFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  BNDEC NOUN> ."
# bn_add: 2 + 3 = 5 (direct + direct)
T "bn_add: 2+3=5"              "0000000000000005" \
    "2 N>N  3 N>N  BN+ NOUN> ."
# bn_add: 0 + 0 = 0
T "bn_add: 0+0=0"              "0000000000000000" \
    "0 N>N  0 N>N  BN+ NOUN> ."
# bn_add: (2^62-1) + 1 = 2^62 (indirect atom); ATOM? true
T "bn_add: boundary to indirect" "FFFFFFFFFFFFFFFF" \
    "4611686018427387903 N>N  1 N>N  BN+ ATOM? ."
# bn_add: 2^62 + 2^62 = 2^63 (indirect); ATOM? true
T "bn_add: 2^62+2^62 indirect"  "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     BN+ ATOM? ."
# bn_dec after bn_add roundtrip: (2^62 + 2^62) - 1 = 2^63-1; ATOM? true
T "bn_add/dec roundtrip"        "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     BN+  BNDEC ATOM? ."

# N. decimal output tests (TD captures decimal strings)
TD "N.: zero"                  "0"                    "0 N>N N."
TD "N.: small decimal"         "42"                   "42 N>N N."
TD "N.: 2^62-1 direct"         "4611686018427387903"  "4611686018427387903 N>N N."
# N. on indirect atom 2^62 (result of bn_inc at boundary)
TD "N.: 2^62 indirect"         "4611686018427387904" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  N."
# N. on 2^62 + 2^62 = 2^63
TD "N.: 2^63"                  "9223372036854775808" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     BN+  N."

# ── Phase 4d: bit ops, shifts, multiply ───────────────────────────────────
# bn_met (result is raw integer, use .)
T "bn_met: 0"              "0000000000000000" "0 N>N BNMET ."
T "bn_met: 1"              "0000000000000001" "1 N>N BNMET ."
T "bn_met: 4"              "0000000000000003" "4 N>N BNMET ."
T "bn_met: 2^62-1"         "000000000000003E" "4611686018427387903 N>N BNMET ."
# bn_met on indirect atom 2^62 → 63 bits
T "bn_met: 2^62 indirect"  "000000000000003F" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  BNMET ."

# bn_bex (result is atom noun)
T "bn_bex: 0 = 1"          "0000000000000001" "0 BNBEX NOUN> ."
T "bn_bex: 3 = 8"          "0000000000000008" "3 BNBEX NOUN> ."
T "bn_bex: 62 = indirect"  "FFFFFFFFFFFFFFFF" "62 BNBEX ATOM? ."
# bex(62) == inc(max_direct): lsh(1,62) == inc(2^62-1)
T "bn_bex: 62 value"       "FFFFFFFFFFFFFFFF" \
    "62 BNBEX  0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  =NOUN ."

# bn_lsh
T "bn_lsh: no-op"          "0000000000000007" "7 N>N 0 BNLSH NOUN> ."
T "bn_lsh: by 3"           "0000000000000038" "7 N>N 3 BNLSH NOUN> ."
T "bn_lsh: 1<<62 indirect" "FFFFFFFFFFFFFFFF" "1 N>N 62 BNLSH ATOM? ."
# lsh(1,62) == bex(62)
T "bn_lsh: eq bex"         "FFFFFFFFFFFFFFFF" "1 N>N 62 BNLSH  62 BNBEX  =NOUN ."

# bn_rsh
T "bn_rsh: no-op"          "0000000000000007" "7 N>N 0 BNRSH NOUN> ."
T "bn_rsh: by 3"           "0000000000000001" "8 N>N 3 BNRSH NOUN> ."
T "bn_rsh: full shift"     "0000000000000000" "1 N>N 1 BNRSH NOUN> ."
# lsh then rsh roundtrip: rsh(lsh(7,10), 10) = 7
T "bn_lsh/rsh roundtrip"   "0000000000000007" "7 N>N 10 BNLSH 10 BNRSH NOUN> ."
# rsh on indirect: rsh(2^62, 1) = 2^61 (direct)
T "bn_rsh: indirect→direct" "2000000000000000" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  1 BNRSH NOUN> ."

# bn_or / bn_and / bn_xor
T "bn_or:  5|3=7"          "0000000000000007" "5 N>N 3 N>N BNOR  NOUN> ."
T "bn_and: 5&3=1"          "0000000000000001" "5 N>N 3 N>N BNAND NOUN> ."
T "bn_xor: 5^3=6"          "0000000000000006" "5 N>N 3 N>N BNXOR NOUN> ."
# or with indirect: or(2^62, 1) should be indirect (> 2^62-1)
T "bn_or: indirect result" "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     1 N>N  BNOR ATOM? ."
# xor is own inverse: xor(xor(a,b),b) = a
T "bn_xor: self-inverse"   "FFFFFFFFFFFFFFFF" \
    "42 N>N  99 N>N  BNXOR  99 N>N  BNXOR  42 N>N  =NOUN ."

# bn_mul
T "bn_mul: 0*5=0"          "0000000000000000" "0 N>N 5 N>N BNMUL NOUN> ."
T "bn_mul: 3*4=12"         "000000000000000C" "3 N>N 4 N>N BNMUL NOUN> ."
T "bn_mul: 6*7=42"         "000000000000002A" "6 N>N 7 N>N BNMUL NOUN> ."
# 2^31 * 2^31 = 2^62 (indirect)
T "bn_mul: 2^31*2^31 indirect" "FFFFFFFFFFFFFFFF" \
    "2147483648 N>N  2147483648 N>N  BNMUL ATOM? ."
# 2^31 * 2^31 == bex(62)
T "bn_mul: 2^31*2^31==bex(62)" "FFFFFFFFFFFFFFFF" \
    "2147483648 N>N  2147483648 N>N  BNMUL  62 BNBEX  =NOUN ."
# mul is lsh by k for power-of-two: 7 * 8 = lsh(7, 3)
T "bn_mul: eq lsh"         "FFFFFFFFFFFFFFFF" \
    "7 N>N 8 N>N BNMUL  7 N>N 3 BNLSH  =NOUN ."
TD "bn_mul: 2^31*2^31 decimal" "4611686018427387904" \
    "2147483648 N>N  2147483648 N>N  BNMUL  N."

# ── jam / cue (Phase 5a) ────────────────────────────────────────────────────
# jam encoding: verified against Python pynoun / Hoon reference
# jam(0)=2  jam(1)=12  jam(2)=72  jam(42)=5456  jam([0 0])=41  jam([1 2])=4657
TD "jam: atom 0"            "2"    "0 N>N JAM N."
TD "jam: atom 1"            "12"   "1 N>N JAM N."
TD "jam: atom 2"            "72"   "2 N>N JAM N."
TD "jam: atom 42"           "5456" "42 N>N JAM N."
TD "jam: [0 0]"             "41"   "0 N>N 0 N>N CONS JAM N."
TD "jam: [1 2]"             "4657" "1 N>N 2 N>N CONS JAM N."

# cue: decode jam output back to original noun
T "cue: 2 -> 0"             "0000000000000000" "2 N>N CUE NOUN> ."
T "cue: 12 -> 1"            "0000000000000001" "12 N>N CUE NOUN> ."
T "cue: 41 head -> 0"       "0000000000000000" "41 N>N CUE CAR NOUN> ."
T "cue: 41 tail -> 0"       "0000000000000000" "41 N>N CUE CDR NOUN> ."
T "cue: 4657 head -> 1"     "0000000000000001" "4657 N>N CUE CAR NOUN> ."
T "cue: 4657 tail -> 2"     "0000000000000002" "4657 N>N CUE CDR NOUN> ."

# round-trip: cue(jam(n)) == n
T "rt: jam(cue(41))==41"    "FFFFFFFFFFFFFFFF" \
    "41 N>N CUE JAM  41 N>N  =NOUN ."
T "rt: jam(cue(4657))==4657" "FFFFFFFFFFFFFFFF" \
    "4657 N>N CUE JAM  4657 N>N  =NOUN ."
T "rt: cue(jam([1 2]))==[1 2]" "FFFFFFFFFFFFFFFF" \
    "1 N>N 2 N>N CONS  DUP JAM CUE  =NOUN ."

# ── Phase 5b: %wild jet dispatch ──────────────────────────────────────────
# JCORE1/JCORE2 build synthetic gate cores; JD wraps them in op9;
# JWRAP adds the op11 %wild registration so jets fire via hot_state[].
# Cord values (LSB = first char): %dec=6514020 %add=6579297 %sub=6452595
#   %mul=7107949 %lth=6845548 %gth=6845543 %lte=6648940 %gte=6648935

T "jet dec: dec(5)=4"          "0000000000000004" \
    "0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  NOCK  NOUN> ."
T "jet dec: dec(1)=0"          "0000000000000000" \
    "0 N>N  6514020 N>N  1 N>N  JCORE1 JD JWRAP  NOCK  NOUN> ."
T "jet add: add(3,4)=7"        "0000000000000007" \
    "0 N>N  6579297 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet add: add(0,0)=0"        "0000000000000000" \
    "0 N>N  6579297 N>N  0 N>N  0 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet sub: sub(10,3)=7"       "0000000000000007" \
    "0 N>N  6452595 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet sub: sub(5,5)=0"        "0000000000000000" \
    "0 N>N  6452595 N>N  5 N>N  5 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet mul: mul(6,7)=42"       "000000000000002A" \
    "0 N>N  7107949 N>N  6 N>N  7 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet mul: mul(0,99)=0"       "0000000000000000" \
    "0 N>N  7107949 N>N  0 N>N  99 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet lth: lth(3,4)=YES"      "0000000000000000" \
    "0 N>N  6845548 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet lth: lth(4,3)=NO"       "0000000000000001" \
    "0 N>N  6845548 N>N  4 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet gth: gth(5,3)=YES"      "0000000000000000" \
    "0 N>N  6845543 N>N  5 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet lte: lte(3,3)=YES"      "0000000000000000" \
    "0 N>N  6648940 N>N  3 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet lte: lte(4,3)=NO"       "0000000000000001" \
    "0 N>N  6648940 N>N  4 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet gte: gte(5,5)=YES"      "0000000000000000" \
    "0 N>N  6648935 N>N  5 N>N  5 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet gte: gte(2,5)=NO"       "0000000000000001" \
    "0 N>N  6648935 N>N  2 N>N  5 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."

# ── Build input and run ────────────────────────────────────────────────────
INPUT="$PREAMBLE"
for line in "${TLINES[@]}"; do
    INPUT+=$'\n'"$line"
done

RAW=$(printf '%s\n' "$INPUT" | \
    timeout 15 qemu-system-aarch64 -machine raspi3b -kernel kernel8.img \
        -display none -nographic 2>/dev/null || true)

# Extract results from output lines.
# Each test produces one output token followed by whitespace and "ok".
# Hex tests: 16-char hex token  → stored as "hex:HEXVALUE"
# Decimal tests: decimal token  → stored as "dec:DECVALUE"
ACTUAL=()
while IFS= read -r line; do
    line="${line%$'\r'}"   # strip CR from CRLF
    if [[ "$line" =~ ^([0-9A-Fa-f]{16})[[:space:]]+ok ]]; then
        ACTUAL+=("hex:${BASH_REMATCH[1]^^}")
    elif [[ "$line" =~ ^([0-9]+)[[:space:]]+ok ]]; then
        ACTUAL+=("dec:${BASH_REMATCH[1]}")
    fi
done <<< "$RAW"

# Compare
N="${#TNAMES[@]}"
ACTUAL_N="${#ACTUAL[@]}"

if (( ACTUAL_N != N )); then
    echo -e "${YEL}WARNING: expected $N results, got $ACTUAL_N${NC}"
fi

for (( i=0; i<N; i++ )); do
    exp="${TEXPECT[$i]}"
    got="${ACTUAL[$i]-MISSING}"
    if [[ "$got" == "$exp" ]]; then
        (( PASS++ ))
        [[ $VERBOSE -eq 1 ]] && echo -e "${GRN}PASS${NC}  ${TNAMES[$i]}"
    else
        (( FAIL++ ))
        echo -e "${RED}FAIL${NC}  ${TNAMES[$i]}"
        echo "      expected: $exp"
        echo "      got:      $got"
    fi
done

echo ""
TOTAL=$(( PASS + FAIL ))
if (( FAIL == 0 )); then
    echo -e "${GRN}$PASS/$TOTAL passed${NC}"
else
    echo -e "${RED}$PASS/$TOTAL passed, $FAIL failed${NC}"
    exit 1
fi
