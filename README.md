# Trinitite
### Native Nock/Forth OS for Raspberry Pi

![](./img/hero.jpg)

Trinitite is a tiny operating system for Raspberry Pi 4/5, written in Forth with a C memory arena.  It boots directly into a Forth/Nock REPL, with no userspace/kernel distinction.  The kernel provides a minimal set of primitives for working with nouns, evaluating Nock formulas, and loading jammed atoms from QEMU's file-loader device.  The REPL supports building and evaluating arbitrary Nock subject/formula pairs, either by hand or by loading pre-jammed pairs via PILL.

Trinitite is an experimental platform in which I jammed a lot of half-baked ideas, like live jet loading (as Forth words), a hash-based indirect atom arena, and a Forth-based implementation of a Nock standard library.

## Building

```
make
```

Cross-compile for CI (Ubuntu):

```
make CC=aarch64-linux-gnu-gcc LD=aarch64-linux-gnu-ld \
     OBJCOPY=aarch64-linux-gnu-objcopy
```

## Running

```
make run          # boots into the Forth REPL
make debug        # boots under GDB
make test         # run regression suite (376 tests)
```

## REPL basics

The kernel boots into a bare-metal Forth REPL. Nouns are 64-bit tagged words;
the key words for working with them:

| Word | Stack effect | Description |
|------|-------------|-------------|
| `N>N` | `( n -- noun )` | wrap raw integer as a direct atom |
| `NOUN>` | `( noun -- n )` | extract raw integer from a direct atom |
| `CONS` | `( head tail -- cell )` | allocate a cell |
| `CAR` | `( cell -- head )` | head of a cell |
| `CDR` | `( cell -- tail )` | tail of a cell |
| `ATOM?` | `( noun -- flag )` | `-1` if atom, `0` if cell |
| `NOCK` | `( subject formula -- result )` | evaluate Nock |
| `JAM` | `( noun -- atom )` | serialize noun to atom |
| `CUE` | `( atom -- noun )` | deserialize atom to noun |
| `PILL` | `( -- atom )` | load jammed atom from QEMU file loader |
| `.` | `( n -- )` | print top of stack as 16-digit hex |
| `N.` | `( noun -- )` | print atom as decimal |

## Running arbitrary Nock subject/formula pairs

### 1. Build inline at the REPL

`NOCK` consumes `( subject formula -- result )`. Build nouns with `N>N` and
`CONS`. Nock cells are right-associative: `[a b c]` = `[a [b c]]`, so push
`a`, push `b`, push `c`, then `CONS CONS`.

```forth
\ *[42 [0 1]] = 42  (slot 1 of atom)
42 N>N   0 N>N 1 N>N CONS   NOCK NOUN> .

\ *[42 [4 [0 1]]] = 43  (increment)
42 N>N   4 N>N 0 N>N 1 N>N CONS CONS   NOCK NOUN> .

\ *[0 [1 [1 2]]] = [1 2]  (quote a cell), print head
0 N>N   1 N>N   1 N>N 2 N>N CONS CONS   NOCK CAR NOUN> .
```

General rule: work **right-to-left** — innermost subterms first, then `CONS`
outward.

### 2. Load a pre-jammed pair via PILL

For formulas too large to type, jam `[subject formula]` externally and load it
via QEMU's file-loader device.

**Pill file format** (little-endian):
- bytes 0–7: `uint64_t` = byte count of jam data that follows
- bytes 8+: raw jam bytes (little-endian bignum)

**Create a pill** from a raw jam file:

```python
import sys, struct
d = open('formula.jam', 'rb').read()
open('pill.bin', 'wb').write(struct.pack('<Q', len(d)) + d)
```

**Run with the pill loaded** (loads at physical address `0x10000000`):

```
make run-pill PILL=pill.bin
```

**Decode and evaluate in the REPL:**

```forth
PILL CUE           \ decode the [subject formula] pair noun
DUP CAR SWAP CDR   \ split: subject below, formula on top
NOCK               \ evaluate
```

Or define a helper word once per session:

```forth
: NOCK-PAIR  DUP CAR SWAP CDR NOCK ;
PILL CUE NOCK-PAIR NOUN> .
```

`PILL` returns atom `0` if no pill was loaded (QEMU zeroes RAM at startup).

## Using on real hardware

### What you need

| Item | Notes |
|------|-------|
| Raspberry Pi 4 Model B | 2 GB or 4 GB both work |
| microSD card (≥ 1 GB) | FAT32 formatted |
| USB-to-3.3V serial adapter | CP2102, FT232, CH340, etc. — **3.3 V logic, not 5 V** |
| 3× female-to-female jumper wires | |
| USB power supply for the Pi | |

### SD card setup

Format the card FAT32. Copy three RPi firmware files to the root:

```
bootcode.bin
start.elf
fixup.dat
```

Get them from the [raspberrypi/firmware](https://github.com/raspberrypi/firmware/tree/master/boot)
repo (just those three files — you do not need the kernel from that repo).

Create `config.txt` in the root:

```ini
arm_64bit=1
dtoverlay=disable-bt
enable_uart=1
```

Copy the kernel:

```sh
make
cp kernel8.img /Volumes/<your-sd>/
```

Eject the card and insert it into the Pi.

### UART wiring

The serial console is on UART0 (PL011), exposed on the 40-pin header.
Use **3.3 V logic only** — 5 V will damage the Pi.

```
Pi GPIO 14  (TXD, pin 8)   →  RX  on serial adapter
Pi GPIO 15  (RXD, pin 10)  →  TX  on serial adapter
Pi GND      (pin 6)        →  GND on serial adapter
```

Do **not** connect the adapter's VCC/3.3V/5V pin to the Pi.
Power the Pi from its own USB-C port.

```
40-pin header (looking at the Pi from above, header at top-right):

  pin 1  [ ][ ] pin 2
  ...
  pin 6  [G][ ]       ← GND
  pin 7  [ ][ ]
  pin 8  [T][ ]       ← TXD (GPIO 14)
  pin 9  [ ][ ]
  pin 10 [R][ ]       ← RXD (GPIO 15)
```

### Serial terminal

Find the device:

```sh
ls /dev/cu.usbserial-* /dev/cu.usbmodem* 2>/dev/null
```

Connect at **115200 8N1**:

```sh
screen /dev/cu.usbserial-XXXX 115200
```

Power on the Pi. Within a second or two you should see:

```
Trinitite v0.1  AArch64 Forth
>
```

That is the Forth REPL. Type Forth words and press Enter.
To quit `screen`: `Ctrl-A \`.

### Iterating

After editing source, rebuild and copy:

```sh
make
cp kernel8.img /Volumes/<your-sd>/
# power-cycle the Pi
```

Or with TFTP netboot:

```sh
make deploy TFTP_ROOT=/private/tftpboot
# reset the Pi
```

### Troubleshooting

**No output at all** — check wiring polarity (TX→RX, RX→TX), confirm 3.3 V adapter,
confirm `dtoverlay=disable-bt` and `enable_uart=1` in `config.txt`.

**Garbage characters** — baud rate mismatch; set terminal to exactly 115200.

**Hangs after a few lines** — flow control issue; disable RTS/CTS in your terminal.

**`ok` appears but input is ignored** — check the TX wire (Pi RXD ← adapter TX).

## Release history and roadmap

* [Roadmap](ROADMAP.md)

First public release ("v0.1-alpha", not properly versioned yet) on ~2026.03.13.

<!--
Named releases will be based on US nuclear weapons tests, in roughly chronological order. The first few are:
Trinity
Crossroads
Sandstone
Ranger
Greenhouse
Buster-Jangle
Tumbler-Snapper
Ivy
Upshot-Knothole
Castle
Teapot
Wigwam
Project 56
Redwing
Project 57
Plumbbob
Project 58
Hardtack I
Argus
Hardtack II
Nougat
Sunbeam
Dominic
Fishbowl
Storac
Roller Coaster
Niblick
Whetstone
Flintlock
Latchkey
Crosstie
Bowline
Mandrel
Emery
https://en.wikipedia.org/wiki/List_of_United_States_nuclear_weapons_tests
-->

![](./img/icon-64.png)

© 2026 Sigilante, released under the MIT License
