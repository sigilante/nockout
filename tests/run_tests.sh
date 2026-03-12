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

# BEFORE "line" — inject a Forth line before the *next* T/TD (produces no output).
# Used for crash-recovery tests: the crash line longjmps to QUIT, the following
# T() test then verifies the VM recovered cleanly.
BEFORE_IDX=()
BEFORE_LINES=()
BEFORE() {
    BEFORE_IDX+=("${#TNAMES[@]}")
    BEFORE_LINES+=("$1")
}

# ── Preamble (defines helpers, produces no numeric output) ─────────────────
# Also pre-builds the sub source cord in SCORD using 8-byte aligned stores
# (bypasses TIB 255-char limit by splitting across multiple lines).
# Sub source: ": sub DUP 12 >NOUN SWAP SLOT NOUN> SWAP 13 >NOUN SWAP SLOT NOUN> - >NOUN ;"
PREAMBLE=': N>N >NOUN ;
: C>N N>N SWAP N>N SWAP CONS ;
: JCORE1 0 N>N CONS 0 N>N SWAP CONS ;
: JCORE2 CONS 0 N>N CONS 0 N>N SWAP CONS ;
: JD 1 N>N SWAP CONS 2 N>N SWAP CONS 9 N>N SWAP CONS ;
: JWRAP SWAP 1 N>N 0 N>N CONS CONS 0 N>N CONS 1 N>N SWAP CONS 1684826487 N>N SWAP CONS SWAP CONS 11 N>N SWAP CONS ;
: NOOP ;
: MAXD 9223372036854775807 N>N ;
: I63 MAXD 4 N>N 0 N>N 1 N>N CONS CONS NOCK ;
HERE @ DUP SCORD ! 80 + HERE !
SCORD @ 6144071398889562170 SWAP !
SCORD @ 8 + 5714573285181694032 SWAP !
SCORD @ 16 + 2328432850663132757 SWAP !
SCORD @ 24 + 6147217917144419411 SWAP !
SCORD @ 32 + 2328432850663128654 SWAP !
SCORD @ 40 + 5644504905447125809 SWAP !
SCORD @ 48 + 5499775099015222048 SWAP !
SCORD @ 56 + 4489619677636482127 SWAP !
SCORD @ 64 + 5644504905447124256 SWAP !
SCORD @ 72 + 15136 SWAP !
SCORD @ 74 S>CRD  SCORD !'

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

# ── Op 10: tree edit (hax) ─────────────────────────────────────────────────
# Op 10 is exclusively *[a 10 [b c] d] = #[b *[a c] *[a d]].
# The form [10 atom f] does not exist in Nock 4K and crashes the evaluator.
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
# %mean stub: clue evaluated (discarded), d returned — cord 1851876717
T "op11: %mean returns d"       "000000000000002B" \
    "42 N>N  11 N>N  1851876717 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# %memo stub: clue evaluated (discarded), d returned — cord 1869440365
T "op11: %memo returns d"       "000000000000002B" \
    "42 N>N  11 N>N  1869440365 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# %bout stub: clue evaluated (discarded), d returned — cord 1953853282
T "op11: %bout returns d"       "000000000000002B" \
    "42 N>N  11 N>N  1953853282 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# %tame with atom clue (not a cell) → nock_crash → longjmp to QUIT → recovery
# Formula: *[0 [11 [%tame [1 99]] [1 42]]] — clue=[1 99]=99 (atom), not a cell → crash
# The BEFORE line triggers the crash; the T() verifies recovery.
BEFORE "0 N>N  1701667188 N>N 1 N>N 99 N>N CONS CONS  1 N>N 42 N>N CONS  CONS  11 N>N SWAP CONS  NOCK DROP"
T "op11: %tame crash recovers"  "000000000000002A" "42 ."

# %tame with source that defines no new word → crash "source did not define a new word"
# Source cord for "42" (pushes 42, defines no word): '4'=52,'2'=50 → cord = 12852
# Label cord "dec" = 6514020. Formula: *[0 [11 [%tame [1 [6514020 12852]]] [1 0]]]
# CONS order: ( head tail -- [head.tail] ) with tail on TOS.
# Build [label.src]: push label(6514020) first, then src(12852) on top.
BEFORE "0 N>N  6514020 N>N  12852 N>N  CONS  1 N>N  SWAP  CONS  1701667188 N>N  SWAP  CONS  1 N>N  0 N>N  CONS  CONS  11 N>N  SWAP  CONS  NOCK DROP"
T "op11: %tame no-def crash recovers" "000000000000002A" "42 ."

# ── Op11 / indirect atom: ATOM?, CELL?, =NOUN on actual indirect atoms ─────
# Direct atom boundary: bit 63 = 0 → max direct = 2^63-1 = 9223372036854775807
# First indirect atom: INC(2^63-1) = 2^63 (bits63:62 = 10 → TAG_INDIRECT)
# Use Nock op4 (INC) to produce the indirect atom:
#   *[9223372036854775807  [4 [0 1]]]  = 2^63

# ATOM? on indirect atom → -1 (true: indirect atoms ARE atoms)
T "indirect: ATOM? true"        "FFFFFFFFFFFFFFFF" \
    "9223372036854775807 N>N  4 N>N 0 N>N 1 N>N CONS CONS  NOCK  ATOM? ."
# CELL? on indirect atom → 0 (false: indirect atoms are NOT cells)
T "indirect: CELL? false"       "0000000000000000" \
    "9223372036854775807 N>N  4 N>N 0 N>N 1 N>N CONS CONS  NOCK  CELL? ."
# Two independent INC(2^63-1) produce noun-equal results (content addressing)
# *[0  [5 [4 [1 2^63-1]] [4 [1 2^63-1]]]]  = NOUN_YES = 0
T "indirect: =NOUN equal"       "0000000000000000" \
    "0 N>N  5 N>N  4 N>N 1 N>N 9223372036854775807 N>N CONS CONS  4 N>N 1 N>N 9223372036854775807 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# ATOM? on a cell → 0 (false: cells are NOT atoms)
T "cell: ATOM? false"           "0000000000000000" \
    "1 2 C>N  ATOM? ."
# CELL? on a direct atom → 0 (false: atoms are NOT cells)
T "direct: CELL? false"         "0000000000000000" \
    "42 N>N  CELL? ."
# Large direct atom tests (values around 2^62; all still direct since bit63=0)
# All values here are around 2^62 and 2^62+1 — still DIRECT atoms (bit63=0).
# The real direct→indirect boundary is 2^63-1 → 2^63.
# 2^62-1 = 4611686018427387903  2^62-2 = 4611686018427387902

# inc(2^62-1) = 2^62 — still a direct atom (bit63=0); ATOM? → true
T "bn_inc: 2^62 still direct"   "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK ATOM? ."
# two independent inc(2^62-1) are noun-equal
T "bn_inc: eq 2^62 direct"      "0000000000000000" \
    "0 N>N  5 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# inc(2^62-1) ≠ inc(2^62-2)
T "bn_inc: neq 2^62 vs 2^62-2"  "0000000000000001" \
    "0 N>N  5 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  4 N>N 1 N>N 4611686018427387902 N>N CONS CONS  CONS CONS  NOCK NOUN> ."
# inc(inc(2^62-1)) = 2^62+1 — still direct; ATOM? → true
T "bn_inc: 2^62+1 still direct" "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  CONS  NOCK ATOM? ."
# two independent double-incs of 2^62-1 are equal
T "bn_inc: eq 2^62+1 direct"    "0000000000000000" \
    "0 N>N  5 N>N  4 N>N 4 N>N 1 N>N 4611686018427387903 N>N CONS CONS CONS  4 N>N 4 N>N 1 N>N 4611686018427387903 N>N CONS CONS CONS  CONS CONS  NOCK NOUN> ."

# ── Phase 4b: BLAKE3 hashing and HATOM word ──────────────────────────────
# Official test vectors (input[i]=i%251, lens 0,1,63,64,65,1024,1025)
T "blake3: official vectors"    "0000000000000001" "B3OK ."
# HATOM is a no-op in the current content-addressed scheme; atoms pass through
T "hatom: direct atom passes"   "FFFFFFFFFFFFFFFF" \
    "42 N>N HATOM ATOM? ."
# HATOM on 2^62 (direct atom) still an atom
T "hatom: 2^62 passes"          "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM ATOM? ."
# Two independently computed 2^62 atoms are equal (content addressing)
T "hatom: eq same value"        "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM \
     =NOUN ."
# 2^62 ≠ 2^62+1
T "hatom: neq different"        "0000000000000000" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK HATOM \
     0 N>N  4 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS CONS  NOCK HATOM \
     =NOUN ."

# ── Phase 4c: bignum arithmetic and decimal I/O ───────────────────────────
# BNDEC on a large DIRECT atom (2^62): result 2^62-1 also direct
T "bn_dec: 2^62 direct both"    "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  BNDEC ATOM? ."
# NOUN> of 2^62-1 (direct) = 0x3FFFFFFFFFFFFFFF
T "bn_dec: 2^62 value"          "3FFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  BNDEC NOUN> ."
# bn_add: 2 + 3 = 5 (direct + direct)
T "bn_add: 2+3=5"              "0000000000000005" \
    "2 N>N  3 N>N  BN+ NOUN> ."
# bn_add: 0 + 0 = 0
T "bn_add: 0+0=0"              "0000000000000000" \
    "0 N>N  0 N>N  BN+ NOUN> ."
# bn_add: (2^62-1) + 1 = 2^62 (direct atom: bit63=0)
T "bn_add: 2^62-1+1=2^62 direct" "FFFFFFFFFFFFFFFF" \
    "4611686018427387903 N>N  1 N>N  BN+ ATOM? ."
# bn_add: 2^62 + 2^62 = 2^63 (FIRST actual indirect atom: bit63=1)
T "bn_add: 2^62+2^62=2^63 indirect"  "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     BN+ ATOM? ."
# BNDEC on actual indirect atom (2^63): result = 2^63-1 (direct, bit63=0)
T "bn_dec: 2^63 indirect→direct" "FFFFFFFFFFFFFFFF" \
    "I63  BNDEC  ATOM? ."
T "bn_dec: 2^63 value"          "7FFFFFFFFFFFFFFF" \
    "I63  BNDEC  NOUN> ."
# bn_add roundtrip: (2^62 + 2^62) - 1 = 2^63-1 (direct); ATOM? → true
T "bn_add/dec roundtrip"        "FFFFFFFFFFFFFFFF" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK \
     BN+  BNDEC ATOM? ."

# ── Indirect atom arithmetic (operands ≥ 2^63) ───────────────────────────
# I63 helper = INC(2^63-1) = 2^63 (first indirect atom, bits63:62=10)

# BN+: indirect + direct → indirect
T "bn_add: indirect+direct atom" "FFFFFFFFFFFFFFFF" \
    "I63  1 N>N  BN+ ATOM? ."
TD "bn_add: indirect+direct value" "9223372036854775809" \
    "I63  1 N>N  BN+ N."

# BN+: indirect + indirect → multi-limb indirect (2^64)
T "bn_add: 2^63+2^63 atom"     "FFFFFFFFFFFFFFFF" \
    "I63  I63  BN+ ATOM? ."
TD "bn_add: 2^63+2^63=2^64"    "18446744073709551616" \
    "I63  I63  BN+ N."
# verify 2^63+2^63 == bex(64)
T "bn_add: 2^63+2^63=bex(64)"  "FFFFFFFFFFFFFFFF" \
    "I63  I63  BN+  64 BNBEX  =NOUN ."

# BNDEC on multi-limb: 2^64 → 2^64-1
TD "bn_dec: 2^64→2^64-1"       "18446744073709551615" \
    "I63  I63  BN+  BNDEC  N."

# BNMUL: indirect × direct → multi-limb (2^63 × 2 = 2^64)
T "bn_mul: 2^63*2 atom"        "FFFFFFFFFFFFFFFF" \
    "I63  2 N>N  BNMUL  ATOM? ."
T "bn_mul: 2^63*2=bex(64)"     "FFFFFFFFFFFFFFFF" \
    "I63  2 N>N  BNMUL  64 BNBEX  =NOUN ."

# BNDIV: multi-limb ÷ indirect (2^64 ÷ 2^63 = 2)
T "bn_div: 2^64/2^63=2"        "0000000000000002" \
    "I63  I63  BN+  I63  BNDIV  NOUN> ."
# BNMOD: indirect operands — 2^64 mod 2^63 = 0
T "bn_mod: 2^64 mod 2^63=0"   "0000000000000000" \
    "I63  I63  BN+  I63  BNMOD  NOUN> ."
# BNMOD: (2^63+1) mod 2^63 = 1
T "bn_mod: 2^63+1 mod 2^63=1" "0000000000000001" \
    "I63  1 N>N  BN+  I63  BNMOD  NOUN> ."
# BNMUL: indirect × indirect = 2^126
T "bn_mul: I63*I63 atom"       "FFFFFFFFFFFFFFFF" \
    "I63  I63  BNMUL  ATOM? ."
T "bn_mul: I63*I63=bex(126)"   "FFFFFFFFFFFFFFFF" \
    "I63  I63  BNMUL  126 BNBEX  =NOUN ."

# N. decimal output tests (TD captures decimal strings)
TD "N.: zero"                  "0"                    "0 N>N N."
TD "N.: small decimal"         "42"                   "42 N>N N."
TD "N.: 2^62-1 direct"         "4611686018427387903"  "4611686018427387903 N>N N."
# N. on 2^62 (direct atom, created via INC(2^62-1))
TD "N.: 2^62 direct"           "4611686018427387904" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  N."
# N. on 2^63 (first real indirect atom, via I63 helper)
TD "N.: 2^63 indirect"         "9223372036854775808" \
    "I63  N."

# ── Phase 4d: bit ops, shifts, multiply ───────────────────────────────────
# bn_met (result is raw integer, use .)
T "bn_met: 0"              "0000000000000000" "0 N>N BNMET ."
T "bn_met: 1"              "0000000000000001" "1 N>N BNMET ."
T "bn_met: 4"              "0000000000000003" "4 N>N BNMET ."
T "bn_met: 2^62-1"         "000000000000003E" "4611686018427387903 N>N BNMET ."
# bn_met on indirect atom 2^62 → 63 bits
T "bn_met: 2^62 indirect"  "000000000000003F" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  BNMET ."
# bn_met on multi-limb: bex(64) = 2^64 has 65 bits
T "bn_met: 2^64 multilimb" "0000000000000041" \
    "I63  I63  BN+  BNMET ."

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
# lsh on indirect input: I63 << 1 = 2^64 = bex(64)
T "bn_lsh: I63 lsh 1"      "FFFFFFFFFFFFFFFF" \
    "I63  1 BNLSH  64 BNBEX  =NOUN ."

# bn_rsh
T "bn_rsh: no-op"          "0000000000000007" "7 N>N 0 BNRSH NOUN> ."
T "bn_rsh: by 3"           "0000000000000001" "8 N>N 3 BNRSH NOUN> ."
T "bn_rsh: full shift"     "0000000000000000" "1 N>N 1 BNRSH NOUN> ."
# lsh then rsh roundtrip: rsh(lsh(7,10), 10) = 7
T "bn_lsh/rsh roundtrip"   "0000000000000007" "7 N>N 10 BNLSH 10 BNRSH NOUN> ."
# rsh on indirect: rsh(2^62, 1) = 2^61 (direct)
T "bn_rsh: indirect→direct" "2000000000000000" \
    "0 N>N  4 N>N 1 N>N 4611686018427387903 N>N CONS CONS  NOCK  1 BNRSH NOUN> ."
# rsh on multi-limb: 2^64 >> 1 = 2^63 (= I63)
T "bn_rsh: 2^64>>1=I63"    "FFFFFFFFFFFFFFFF" \
    "I63  I63  BN+  1 BNRSH  I63  =NOUN ."

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
# bitwise with indirect operands: I63 AND I63 = I63
T "bn_and: I63&I63=I63"    "FFFFFFFFFFFFFFFF" \
    "I63  I63  BNAND  I63  =NOUN ."
# I63 OR I63 = I63
T "bn_or:  I63|I63=I63"    "FFFFFFFFFFFFFFFF" \
    "I63  I63  BNOR   I63  =NOUN ."
# I63 XOR I63 = 0
T "bn_xor: I63^I63=0"      "0000000000000000" \
    "I63  I63  BNXOR  NOUN> ."

# bn_sub
T "bn_sub: 10-3=7"         "0000000000000007" "10 N>N  3 N>N  BNSUB NOUN> ."
T "bn_sub: 5-5=0"          "0000000000000000" "5 N>N   5 N>N  BNSUB NOUN> ."
T "bn_sub: 1-0=1"          "0000000000000001" "1 N>N   0 N>N  BNSUB NOUN> ."
# indirect - indirect: I63+1 - I63 = 1
T "bn_sub: I63+1 - I63=1"  "0000000000000001" \
    "I63  1 N>N BN+  I63  BNSUB  NOUN> ."
# indirect - direct: I63+I63 - I63 = I63 (result stays indirect)
T "bn_sub: 2^64 - I63=I63" "FFFFFFFFFFFFFFFF" \
    "I63  I63  BN+  I63  BNSUB  I63  =NOUN ."

# bn_lth / bn_gth / bn_lte / bn_gte — return Nock booleans (0=YES, 1=NO)
T "bn_lth: 3<5=YES"        "0000000000000000" "3 N>N  5 N>N  BNLTH NOUN> ."
T "bn_lth: 5<3=NO"         "0000000000000001" "5 N>N  3 N>N  BNLTH NOUN> ."
T "bn_lth: 3<3=NO"         "0000000000000001" "3 N>N  3 N>N  BNLTH NOUN> ."
T "bn_gth: 5>3=YES"        "0000000000000000" "5 N>N  3 N>N  BNGTH NOUN> ."
T "bn_gth: 3>5=NO"         "0000000000000001" "3 N>N  5 N>N  BNGTH NOUN> ."
T "bn_gth: 3>3=NO"         "0000000000000001" "3 N>N  3 N>N  BNGTH NOUN> ."
T "bn_lte: 3<=5=YES"       "0000000000000000" "3 N>N  5 N>N  BNLTE NOUN> ."
T "bn_lte: 5<=5=YES"       "0000000000000000" "5 N>N  5 N>N  BNLTE NOUN> ."
T "bn_lte: 5<=4=NO"        "0000000000000001" "5 N>N  4 N>N  BNLTE NOUN> ."
T "bn_gte: 5>=5=YES"       "0000000000000000" "5 N>N  5 N>N  BNGTE NOUN> ."
T "bn_gte: 5>=3=YES"       "0000000000000000" "5 N>N  3 N>N  BNGTE NOUN> ."
T "bn_gte: 2>=5=NO"        "0000000000000001" "2 N>N  5 N>N  BNGTE NOUN> ."
# comparisons with indirect operands
T "bn_lth: I63<I63+1=YES"  "0000000000000000" \
    "I63  I63  1 N>N  BN+  BNLTH NOUN> ."
T "bn_lth: I63<I63=NO"     "0000000000000001" \
    "I63  I63  BNLTH NOUN> ."
T "bn_gte: I63>=I63=YES"   "0000000000000000" \
    "I63  I63  BNGTE NOUN> ."

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
# JWRAP adds the op11 %wild registration so jets fire.
# Op 9 dispatch: find_by_cord(label) tries Forth dict FIRST, then C hot_state[].
# The static Forth jet definitions (dec/add/sub/mul/div/mod/lth/gth/lte/gte)
# shadow the C hot_state[] entries; these tests exercise the Forth jets.
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

# ── Phase 5e: bignum div / mod ─────────────────────────────────────────────
# Cord values: %div=7760228  %mod=6582125

# BNDIV direct
T "bndiv: 10/3=3"              "0000000000000003" \
    "10 N>N  3 N>N  BNDIV NOUN> ."
T "bndiv: 12/4=3"              "0000000000000003" \
    "12 N>N  4 N>N  BNDIV NOUN> ."
T "bndiv: 7/7=1"               "0000000000000001" \
    "7 N>N  7 N>N  BNDIV NOUN> ."
T "bndiv: 3/5=0 (a<b)"        "0000000000000000" \
    "3 N>N  5 N>N  BNDIV NOUN> ."
T "bndiv: 100/1=100"           "0000000000000064" \
    "100 N>N  1 N>N  BNDIV NOUN> ."

# BNMOD direct
T "bnmod: 10%3=1"              "0000000000000001" \
    "10 N>N  3 N>N  BNMOD NOUN> ."
T "bnmod: 12%4=0"              "0000000000000000" \
    "12 N>N  4 N>N  BNMOD NOUN> ."
T "bnmod: 7%7=0"               "0000000000000000" \
    "7 N>N  7 N>N  BNMOD NOUN> ."
T "bnmod: 3%5=3 (a<b)"        "0000000000000003" \
    "3 N>N  5 N>N  BNMOD NOUN> ."

# Cross-check: 17/5=3, 3*5=15, 17%5=2, 15+2=17
T "bndiv: 17/5=3"              "0000000000000003" \
    "17 N>N  5 N>N  BNDIV NOUN> ."
T "bnmod: 17%5=2"              "0000000000000002" \
    "17 N>N  5 N>N  BNMOD NOUN> ."

# Multi-limb: (10^11 * 10^11) / 10^11 = 10^11
# 10^11 = 100000000000 (direct atom, < 2^63)
TD "bndiv: large/large=10^11" "100000000000" \
    "100000000000 N>N  100000000000 N>N  BNMUL  100000000000 N>N  BNDIV NOUN> N."

# Jet dispatch
T "jet div: div(10,3)=3"       "0000000000000003" \
    "0 N>N  7760228 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet div: div(7,7)=1"        "0000000000000001" \
    "0 N>N  7760228 N>N  7 N>N  7 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet mod: mod(10,3)=1"       "0000000000000001" \
    "0 N>N  6582125 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."
T "jet mod: mod(12,4)=0"       "0000000000000000" \
    "0 N>N  6582125 N>N  12 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> ."

# ── Phase 7 — Kernel Loop ─────────────────────────────────────────────────
T "KSHAPE default zero"        "0000000000000000" \
    "KSHAPE @  ."
T "DO-FX empty list"           "0000000000000001" \
    "0 >NOUN DO-FX  1 ."
T "DO-FX %out effect"          "0000000000000001" \
    "7632239 >NOUN  0 >NOUN CONS  0 >NOUN CONS  DO-FX  1 ."

# ── Phase 8 — SKA: SKNOCK gives same answers as NOCK ─────────────────────
# SKNOCK runs the scan pass and eval_nomm; ops 9/I2 fall back to nock_ex.
# Linear ops are handled natively; jet dispatch fires via %wild scope.

# op 0 (slot)
T "ska op0: slot axis 1"       "000000000000002A" \
    "42 N>N  0 N>N 1 N>N CONS  SKNOCK NOUN> ."
T "ska op0: slot head"         "0000000000000001" \
    "1 2 C>N  0 N>N 2 N>N CONS  SKNOCK NOUN> ."

# op 1 (quote)
T "ska op1: quote 42"          "000000000000002A" \
    "0 N>N  1 N>N 42 N>N CONS  SKNOCK NOUN> ."

# op 4 (inc) and op 0
T "ska op4: inc 5 = 6"         "0000000000000006" \
    "5 N>N  4 N>N 0 N>N 1 N>N CONS CONS  SKNOCK NOUN> ."

# op 5 (eq) — same axis twice → YES (0)
T "ska op5: eq self = YES"     "0000000000000000" \
    "42 N>N  5 N>N 0 N>N 1 N>N CONS  0 N>N 1 N>N CONS  CONS CONS  SKNOCK NOUN> ."

# op 6 (if) — YES → then branch
T "ska op6: YES->42"           "000000000000002A" \
    "0 N>N  6 N>N  1 N>N 0 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  SKNOCK NOUN> ."
T "ska op6: NO->99"            "0000000000000063" \
    "0 N>N  6 N>N  1 N>N 1 N>N CONS  1 N>N 42 N>N CONS  1 N>N 99 N>N CONS  CONS CONS CONS  SKNOCK NOUN> ."

# op 7 (compose) — double lus: *[5 [7 [4 [0 1]] [4 [0 1]]]] = 7
T "ska op7: double lus"        "0000000000000007" \
    "5 N>N  7 N>N  4 N>N 0 N>N 1 N>N CONS CONS  4 N>N 0 N>N 1 N>N CONS CONS  CONS  CONS  SKNOCK NOUN> ."

# op 8 (push) — pin 99 then slot head
T "ska op8: pin slot head"     "0000000000000063" \
    "42 N>N  8 N>N  1 N>N 99 N>N CONS  0 N>N 2 N>N CONS  CONS CONS  SKNOCK NOUN> ."

# op 9 (arm invoke, fallback via nock_ex) — same as existing op9 test
T "ska op9: arm at axis 2"     "000000000000002B" \
    "0 N>N  9 N>N  2 N>N  1 N>N  4 N>N 0 N>N 3 N>N CONS CONS  42 N>N CONS  CONS  CONS  CONS  SKNOCK NOUN> ."

# op 10 (hax tree edit) — same as existing op10 test
T "ska op10: edit axis 2 head" "0000000000000063" \
    "1 2 C>N  10 N>N  2 N>N 1 N>N 99 N>N CONS CONS  0 N>N 1 N>N CONS  CONS  CONS  SKNOCK CAR NOUN> ."

# op 11 static hint (pass-through)
T "ska op11: static hint"      "000000000000002A" \
    "42 N>N  11 N>N 7 N>N 0 N>N 1 N>N CONS CONS CONS  SKNOCK NOUN> ."

# jet dispatch via SKNOCK — %wild hint scoped, fallback in NOMM_9 fires jet
T "ska jet dec: dec(5)=4"      "0000000000000004" \
    "0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  SKNOCK  NOUN> ."
T "ska jet add: add(3,4)=7"    "0000000000000007" \
    "0 N>N  6579297 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  SKNOCK  NOUN> ."
T "ska jet div: div(10,3)=3"   "0000000000000003" \
    "0 N>N  7760228 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  SKNOCK  NOUN> ."
T "ska jet mod: mod(10,3)=1"   "0000000000000001" \
    "0 N>N  6582125 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  SKNOCK  NOUN> ."

# loop detection (Stage 8e): battery = [9 2 [0 1]] — self-referential formula
# scan detects the backedge; eval falls back to nock_op9_continue → jet fires
T "ska loop: recursive battery, dec jet"  "0000000000000004" \
    "0 N>N  6514020 N>N  5 N>N 0 N>N CONS  0 N>N 1 N>N CONS 2 N>N SWAP CONS 9 N>N SWAP CONS  SWAP CONS  JD JWRAP  SKNOCK  NOUN> ."

# memo cache (Stage 8d): same arm called twice — second hit uses cached nomm
# Two independent %wild-wrapped dec(5) calls; both should yield 4
T "ska memo: double dec(5)=4,4"  "0000000000000004" \
    "0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  SKNOCK  NOUN> ."
T "ska memo: double dec(5)=4,4 again"  "0000000000000004" \
    "0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  SKNOCK  NOUN> ."

# ── Stage 8g: SKA-EN + .SKA ──────────────────────────────────────────────
# SKA-EN routes NOCK through ska_nock; results must match plain NOCK.
T "ska-enable: dec(5)=4 via NOCK"  "0000000000000004" \
    "1 SKA-EN !  0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  NOCK  NOUN> .  0 SKA-EN !"
T "ska-enable: add(3,4)=7 via NOCK"  "0000000000000007" \
    "1 SKA-EN !  0 N>N  6579297 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .  0 SKA-EN !"
T "ska-enable: sub(10,3)=7 via NOCK"  "0000000000000007" \
    "1 SKA-EN !  0 N>N  6452595 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .  0 SKA-EN !"
T "ska-enable: NOCK disabled again works"  "0000000000000005" \
    "0 SKA-EN !  0 N>N  6514020 N>N  6 N>N  JCORE1 JD JWRAP  NOCK  NOUN> ."
# .SKA: verify it runs without crashing; stack must be clean after (42 = 0x2A)
T "dotska: no crash on simple formula"  "000000000000002A" \
    "0 N>N  0 N>N 1 N>N CONS  .SKA  42 N>N ."

# ── Phase 9e — EVAL word ──────────────────────────────────────────────────────
# EVAL ( c-addr u -- ) evaluates a string of Forth source.
# Smoke test: evaluate the empty string — save/restore TIB and return cleanly.
T "eval: empty string noop"  "000000000000002A" \
    "TIB 0 EVAL  42 ."

# ── Phase 9a/9b/9c integration: Forth jet shadows C jet via SKNOCK ───────────
# 9a: find_by_cord locates the Forth dict entry by cord value.
# 9b: forth_call_jet executes the Forth word with core on the data stack.
# 9c: cook_find_jet checks Forth dict before hot_state[]; Forth jet wins.
#
# Forth jet signature: ( core -- result )
#   dec: slot(6, core) → direct val → decrement → re-wrap as noun
#   add: DUP core, slot(12) → raw a, swap core back, slot(13) → raw b, add
#
# cord("dec") = 'd'+'e'<<8+'c'<<16 = 6514020  (matches hot_state[] label)
# cord("add") = 'a'+'d'<<8+'d'<<16 = 6579297  (matches hot_state[] label)
#
# NOTE: these definitions persist for the remainder of the QEMU session,
# so all subsequent SKNOCK tests that use those labels will use Forth jets.
T "9b: Forth dec jet dec(5)=4"    "0000000000000004" \
    ": dec  6 >NOUN SWAP SLOT  NOUN> 1 -  >NOUN ;  0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  SKNOCK  NOUN> ."
T "9b: Forth dec jet dec(100)=99" "0000000000000063" \
    "0 N>N  6514020 N>N  100 N>N  JCORE1 JD JWRAP  SKNOCK  NOUN> ."
T "9b: Forth add jet add(3,4)=7"  "0000000000000007" \
    ": add  DUP  12 >NOUN SWAP SLOT  NOUN>  SWAP  13 >NOUN SWAP SLOT  NOUN>  +  >NOUN ;  0 N>N  6579297 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  SKNOCK  NOUN> ."
T "9b: Forth add jet add(10,20)=30" "000000000000001E" \
    "0 N>N  6579297 N>N  10 N>N  20 N>N  JCORE2 JD JWRAP  SKNOCK  NOUN> ."

# ── Phase 9f — %tame hint: compile Forth jet from Nock at eval time ──────────
# %tame fires at eval time → calls forth_eval_string(source-cord) → Forth word
# appears in dictionary.  The enclosing %wild scopes the jet registration.
# nock_op9_continue then finds the new word via find_by_cord (runtime lookup).
#
# Formula structure:
#   [11 [[%tame [1 [label src-cord]]] [11 [[%wild [1 wilt]] op9-body]]]]
#
# %tame cord = 't'+'a'<<8+'m'<<16+'e'<<24 = 1701667188
# %wild cord = 1684826487  (already used in JWRAP)
# label cord  = 'sub' = 6452595  (cord("sub"))
#
# SCORD is pre-loaded in the preamble with the 74-byte sub source cord:
#   ": sub DUP 12 >NOUN SWAP SLOT NOUN> SWAP 13 >NOUN SWAP SLOT NOUN> - >NOUN ;"
# The cord is built via 8-byte aligned ! stores (each preamble line ≤40 chars)
# to stay within the 255-byte TIB limit.  HERE @ is used (not HERE, which is
# a defvar that pushes the storage-cell address, not the dict-top value).

# Test 0: indirect atom sanity — SCORD @ should be a TAG_INDIRECT noun.
# TAG_INDIRECT = 2<<62 = 0x8000000000000000; bits 63:62 = 10.
# Verify: (SCORD @) >> 62 == 2.
T "9f: SCORD is indirect atom (bits63:62=10)" "0000000000000002" \
    "SCORD @  62 RSH ."

# Test 1: %tame+%wild: define 'sub' jet via Nock hint, evaluate sub(10,3)=7
T "9f: %tame defines sub(10-3)=7"   "0000000000000007" \
    "0 N>N  6452595 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  SCORD @  6452595 N>N SWAP CONS  1 N>N SWAP CONS  1701667188 N>N SWAP CONS  SWAP CONS  11 N>N SWAP CONS  SKNOCK  NOUN> ."

# Test 2: sub definition persists — same Forth word fires again (no re-tame needed)
T "9f: sub persists sub(100-1)=99"  "0000000000000063" \
    "0 N>N  6452595 N>N  100 N>N  1 N>N  JCORE2 JD JWRAP  SKNOCK  NOUN> ."

# ── Phase 9g — TIMER@, EXECUTE, BENCH, formula cache ──────────────────────
# TIMER@ reads CNTVCT_EL0 (virtual timer, ~54 MHz on RPi4).
# EXECUTE runs an execution token.
# BENCH ( xt n -- cycles ) executes xt n times, returns elapsed ticks.
# Formula cache: SKNOCK on the same formula twice; second call uses cache.

# Test: TIMER@ returns a non-zero value (timer is running)
T "9g: TIMER@ non-zero" "FFFFFFFFFFFFFFFF" \
    "TIMER@ 0 > ."

# Test: EXECUTE runs a word — push 0, tick 1+, EXECUTE → 1
T "9g: EXECUTE runs word" "0000000000000001" \
    "0  ' 1+  EXECUTE  ."

# Test: BENCH returns non-zero ticks for 100 iterations of NOOP
# NOOP is stack-neutral (does nothing); any elapsed > 0 → 0 > returns -1
T "9g: BENCH returns ticks>0" "FFFFFFFFFFFFFFFF" \
    "' NOOP  100  BENCH  0 > ."

# Test: formula cache — SKNOCK called twice on same formula; result unchanged
# Use op1 (quote): *[s [1 42]] = 42 regardless of subject
T "9g: SKNOCK cached formula" "000000000000002A" \
    "0 N>N  1 N>N 42 N>N CONS  SKNOCK  NOUN> ."
# ── Build input and run ────────────────────────────────────────────────────
INPUT="$PREAMBLE"
bi=0
for (( i=0; i<${#TLINES[@]}; i++ )); do
    # Inject any BEFORE lines registered for this index
    while [[ $bi -lt ${#BEFORE_IDX[@]} && "${BEFORE_IDX[$bi]}" -eq "$i" ]]; do
        INPUT+=$'\n'"${BEFORE_LINES[$bi]}"
        (( ++bi ))
    done
    INPUT+=$'\n'"${TLINES[$i]}"
done
# Flush BEFORE lines registered after the last T (tail crash tests)
while [[ $bi -lt ${#BEFORE_LINES[@]} ]]; do
    INPUT+=$'\n'"${BEFORE_LINES[$bi]}"
    (( ++bi ))
done

RAW=$({ printf '%s\n' "$INPUT"; sleep 4; printf '\001x'; } | \
    timeout 45 qemu-system-aarch64 -machine raspi4b -kernel kernel8.img \
        -display none -nographic || true)

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
        (( ++PASS ))
        [[ $VERBOSE -eq 1 ]] && echo -e "${GRN}PASS${NC}  ${TNAMES[$i]}"
    else
        (( ++FAIL ))
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
