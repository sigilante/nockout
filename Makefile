TARGET  = kernel8
SRCDIR  = src

CROSS   ?= aarch64-elf-
CC       = $(CROSS)gcc
LD       = $(CROSS)ld
OBJCOPY  = $(CROSS)objcopy
GDB      = $(CROSS)gdb

VPATH   = $(SRCDIR)

CFLAGS  = -Wall -O2 -ffreestanding -nostdlib -nostartfiles \
          -mcpu=cortex-a72 -mgeneral-regs-only \
          -fno-pic -fno-stack-protector \
          -I$(SRCDIR)
LDFLAGS = -T $(SRCDIR)/linker.ld -nostdlib

OBJS    = boot.o uart.o noun.o bignum.o blake3.o nock.o setjmp.o jam.o kernel.o forth.o main.o

all: $(TARGET).img

%.o: %.s
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET).elf: $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $^

$(TARGET).img: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

run: $(TARGET).img
	qemu-system-aarch64 \
	  -machine raspi4b \
	  -kernel $(TARGET).img \
	  -display none \
	  -nographic

# Load a pill into QEMU memory and run the kernel loop.
# Build pill with: python3 tools/mkpill.py <jam-file> <arvo|shrine> pill.bin
# The shape byte in the pill selects Arvo or Shrine mode automatically.
# With no pill: falls back to interactive REPL.
PILL ?= pill.bin
run-pill: $(TARGET).img
	qemu-system-aarch64 \
	  -machine raspi4b \
	  -kernel $(TARGET).img \
	  -device loader,file=$(PILL),addr=0x10000000,force-raw=on \
	  -display none \
	  -nographic

run-kernel: run-pill

debug: $(TARGET).img
	qemu-system-aarch64 \
	  -machine raspi4b \
	  -kernel $(TARGET).img \
	  -display none \
	  -nographic \
	  -s -S &
	sleep 1
	$(GDB) $(TARGET).elf \
	  -ex "target remote :1234" \
	  -ex "break main" \
	  -ex "continue"

TFTP_ROOT ?= /private/tftpboot
deploy: $(TARGET).img
	cp $(TARGET).img $(TFTP_ROOT)/
	@echo "Deployed. Reset the Pi."

test:
	./tests/run_tests.sh

clean:
	rm -f *.o *.elf *.img

.PHONY: all run run-pill run-kernel debug deploy test clean
