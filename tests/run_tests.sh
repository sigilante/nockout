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
    TEXPECT+=("$2")
    TLINES+=("$3")
}

# ── Preamble (defines helpers, produces no numeric output) ─────────────────
PREAMBLE=': N>N >NOUN ;
: C>N N>N SWAP N>N SWAP CONS ;'

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

# ── Build input and run ────────────────────────────────────────────────────
INPUT="$PREAMBLE"
for line in "${TLINES[@]}"; do
    INPUT+=$'\n'"$line"
done

RAW=$(printf '%s\n' "$INPUT" | \
    timeout 15 qemu-system-aarch64 -machine raspi3b -kernel kernel8.img \
        -display none -nographic 2>/dev/null || true)

# Extract 16-char uppercase hex values that appear before "  ok"
ACTUAL=()
while IFS= read -r line; do
    line="${line%$'\r'}"   # strip CR from CRLF
    if [[ "$line" =~ ^([0-9A-Fa-f]{16})[[:space:]]+ok ]]; then
        ACTUAL+=("${BASH_REMATCH[1]^^}")  # uppercase
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
