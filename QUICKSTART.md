# Nockout — Quick Start

Running the bare-metal Forth/Nock OS on a Raspberry Pi 3B/3B+.

## Hardware

| Item | Notes |
|------|-------|
| Raspberry Pi 3B or 3B+ | 3A+ also works |
| microSD card (≥ 1 GB) | FAT32 formatted |
| USB-to-3.3V serial adapter | CP2102, FT232, CH340, etc. — **3.3 V logic, not 5 V** |
| 3× female-to-female jumper wires | |
| USB power supply for the Pi | |

## 1 — Build

```sh
make
```

Produces `kernel8.img`. Requires `aarch64-elf-gcc` and `aarch64-elf-ld` on your PATH
(e.g. from Homebrew `aarch64-elf-gcc` or a cross-toolchain tarball).

## 2 — SD Card

Format the card FAT32. Copy the three RPi firmware files to the root:

```
bootcode.bin
start.elf
fixup.dat
```

Get them from the [raspberrypi/firmware](https://github.com/raspberrypi/firmware/tree/master/boot)
repo (just those three files — you do not need the kernel from that repo).

Create `config.txt` in the root:

```ini
# 64-bit bare-metal kernel
arm_64bit=1

# Route PL011 UART to GPIO 14/15; disable Bluetooth which steals PL011
dtoverlay=disable-bt
enable_uart=1
```

Copy the kernel:

```sh
cp kernel8.img /Volumes/<your-sd>/
```

Eject the card and insert it into the Pi.

## 3 — UART Wiring

The serial console is on UART0 (PL011), exposed on the 40-pin header.
Use **3.3 V logic only** — 5 V will damage the Pi.

```
Pi GPIO 14  (TXD, pin 8)   →  RX  on serial adapter
Pi GPIO 15  (RXD, pin 10)  →  TX  on serial adapter
Pi GND      (pin 6)        →  GND on serial adapter
```

Do **not** connect the adapter's VCC/3.3V/5V pin to the Pi.
Power the Pi from its own USB Micro-B port.

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

## 4 — Serial Terminal

Find the device:

```sh
ls /dev/cu.usbserial-* /dev/cu.usbmodem-* 2>/dev/null
```

Connect at **115200 8N1**:

```sh
# screen
screen /dev/cu.usbserial-XXXX 115200

# minicom
minicom -b 115200 -D /dev/cu.usbserial-XXXX

# picocom
picocom -b 115200 /dev/cu.usbserial-XXXX
```

Power on the Pi. Within a second or two you should see:

```
ok
```

That is the Forth REPL. Type Forth words and press Enter.

To quit `screen`: `Ctrl-A \`. To quit `minicom`/`picocom`: `Ctrl-A X`.

## 5 — Interacting Without Networking

**UART is the only interface, and that is sufficient.**

Everything the OS does is visible on the serial line:

| What you see | Source |
|---|---|
| `ok` prompt | Forth REPL ready |
| Hex values from `.` | Stack values printed by Forth |
| Decimal values from `N.` | Bignum atoms |
| `%slog` output | Nock debug hint |
| `%xray` dumps | Recursive noun tree print |
| Phase 6 effect output | `%out`/`%blit` effects from the kernel loop |

For Phase 6 kernel-loop mode, events go **in** over UART (length-prefixed jam bytes)
and effects come **back out** over the same wire. A host-side Python script handles
framing; see `tools/mkpill.py` and `tools/send_event.py` (Phase 6).

For debugging without a host script, you can drop back to the Forth REPL:
if no PILL is loaded, `KERNEL` falls through to `QUIT` (the REPL).
You can also call `PILL CUE` manually and inspect nouns with `.`, `CAR`, `CDR`.

### Quick Forth sanity check

```forth
42 .                    \ 000000000000002A  ok
1 2 C>N CAR NOUN> .     \ 0000000000000001  ok
10 N>N 3 N>N BN+ NOUN> .\ 000000000000000D  ok
```

## 6 — Iterating

After editing source, rebuild and copy:

```sh
make
cp kernel8.img /Volumes/<your-sd>/
# power-cycle the Pi
```

Or if you have a TFTP server set up on the host:

```sh
make deploy TFTP_ROOT=/private/tftpboot
# then reset the Pi
```

## 7 — QEMU (no hardware needed)

```sh
make run          # interactive REPL in the terminal
make test         # run full regression suite (155 tests)
make run-pill PILL=pill.bin   # boot with a kernel pill loaded
```

QEMU exits cleanly via `Ctrl-A X`.

## Memory Layout (reference)

| Region | Address | Size |
|--------|---------|------|
| Code + data | `0x80000` | ~512 KB |
| TIB (terminal input) | `0x8F000` | 4 KB |
| Forth stacks | `0x90000` | 4 KB |
| UART RX buffer (Phase 6) | `0x91000` | 28 KB |
| Noun heap (cells) | `0x100000` | grows up |
| Atom index (hash table) | `0x200000` | 1 MB |
| Atom data (bump alloc) | `0x300000` | 4 MB |
| PILL load address | `0x10000000` | — |

## Troubleshooting

**No output at all** — check wiring polarity (TX→RX, RX→TX), confirm 3.3 V adapter,
confirm `dtoverlay=disable-bt` and `enable_uart=1` in `config.txt`.

**Garbage characters** — baud rate mismatch; set terminal to exactly 115200.

**Hangs after a few lines** — flow control enabled on the terminal; disable RTS/CTS
(`screen`: no extra flags needed; `minicom`: turn off hardware flow control in settings).

**`ok` appears but input is ignored** — check the TX wire (Pi RXD ← adapter TX).
