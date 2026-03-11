#!/usr/bin/env bash
# tests/kernel-boot.sh — kernel event-loop integration tests
#
# Builds pills from precomputed jam atoms and boots them under QEMU raspi4b.
# Tests both passive boot behaviour (banner) and active hint firing (%slog).
#
# Precomputed atoms (all hand-crafted, verified by tools/jam.py test):
#
#   null-arvo   3533463315829630395733151849237  |=(* [~ self])     Arvo shape
#   hint-arvo   103461740246623566125433280773   %slog on event     Arvo shape
#   null-shrine 89337781013                      |=(* [~ self ~])   Shrine shape
#   hint-shrine 13497664181327658059184875019360517  %slog + shrine
#
# hint kernels emit:  slog: 000000000000002a
# when sent event = atom 42 (jam(42) = 5456 = bytes 0x50 0x15)
#
# Usage:  bash tests/kernel-boot.sh [--verbose]

set -euo pipefail
cd "$(dirname "$0")/.."

VERBOSE=0
[[ "${1-}" == "--verbose" ]] && VERBOSE=1

RED='\033[0;31m'
GRN='\033[0;32m'
NC='\033[0m'

PASS=0; FAIL=0

check() {
    local name="$1" pattern="$2" out="$3"
    if printf '%s' "$out" | grep -q "$pattern"; then
        (( ++PASS ))
        echo -e "${GRN}PASS${NC}  $name"
        [[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out" | head -8 | sed 's/^/      /'
    else
        (( ++FAIL ))
        echo -e "${RED}FAIL${NC}  $name"
        echo "      expected to find: $pattern"
        printf '%s\n' "$out" | head -8 | sed 's/^/      got: /'
    fi
}

# ── Build pills ───────────────────────────────────────────────────────────────
TMPDIR_PILLS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PILLS"' EXIT

python3 tools/mkpill.py -n 3533463315829630395733151849237          arvo   "$TMPDIR_PILLS/null-arvo.pill"
python3 tools/mkpill.py -n 103461740246623566125433280773           arvo   "$TMPDIR_PILLS/hint-arvo.pill"
python3 tools/mkpill.py -n 89337781013                              shrine "$TMPDIR_PILLS/null-shrine.pill"
python3 tools/mkpill.py -n 13497664181327658059184875019360517      shrine "$TMPDIR_PILLS/hint-shrine.pill"

QEMU="qemu-system-aarch64 -machine raspi4b -display none -nographic"
IMG="-kernel kernel8.img"

# ── Test helpers ──────────────────────────────────────────────────────────────

boot_nopill() {
    # Boot without any pill — should fall back to REPL (QUIT)
    { sleep 1; printf '\001x'; } | \
        timeout 5 $QEMU $IMG 2>/dev/null || true
}

boot_pill() {
    local pill="$1"
    { sleep 2; printf '\001x'; } | \
        timeout 6 $QEMU $IMG \
          -device "loader,addr=0x10000000,force-raw=on,file=$pill" \
          2>/dev/null || true
}

# Send event = atom 42.
#   jam(42) = 5456 = 0x1550, little-endian bytes: 0x50 0x15
#   uart_recv_noun protocol: 8-byte LE length (=2) then jam bytes
boot_pill_event42() {
    local pill="$1"
    { sleep 2
      python3 -c "import sys; sys.stdout.buffer.write(bytes([2,0,0,0,0,0,0,0,0x50,0x15]))" 2>/dev/null
      sleep 1
      printf '\001x'
    } | timeout 8 $QEMU $IMG \
          -device "loader,addr=0x10000000,force-raw=on,file=$pill" \
          2>/dev/null || true
}

# ── Tests ─────────────────────────────────────────────────────────────────────

check "no-pill: REPL boot"         "Fock v0.1"             "$(boot_nopill)"
check "null-arvo: kernel banner"   "fock arvo"             "$(boot_pill   "$TMPDIR_PILLS/null-arvo.pill")"
check "null-shrine: kernel banner" "fock shrine"           "$(boot_pill   "$TMPDIR_PILLS/null-shrine.pill")"
check "hint-arvo: %slog on event"  "000000000000002a"      "$(boot_pill_event42 "$TMPDIR_PILLS/hint-arvo.pill")"
check "hint-shrine: %slog on event" "000000000000002a"     "$(boot_pill_event42 "$TMPDIR_PILLS/hint-shrine.pill")"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
TOTAL=$(( PASS + FAIL ))
if (( FAIL == 0 )); then
    echo -e "${GRN}$PASS/$TOTAL passed${NC}"
else
    echo -e "${RED}$PASS/$TOTAL passed, $FAIL failed${NC}"
    exit 1
fi
