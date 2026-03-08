TARGET  = kernel8
SRCDIR  = src

CC      = aarch64-elf-gcc
LD      = aarch64-elf-ld
OBJCOPY = aarch64-elf-objcopy
GDB     = aarch64-elf-gdb

VPATH   = $(SRCDIR)

CFLAGS  = -Wall -O2 -ffreestanding -nostdlib -nostartfiles \
          -mcpu=cortex-a53 -mgeneral-regs-only \
          -fno-pic -fno-stack-protector \
          -I$(SRCDIR)
LDFLAGS = -T $(SRCDIR)/linker.ld -nostdlib

OBJS    = boot.o uart.o noun.o bignum.o blake3.o nock.o setjmp.o jam.o forth.o main.o

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
	  -machine raspi3b \
	  -kernel $(TARGET).img \
	  -display none \
	  -nographic

debug: $(TARGET).img
	qemu-system-aarch64 \
	  -machine raspi3b \
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

.PHONY: all run debug deploy test clean
