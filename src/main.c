#include <stdint.h>
#include "uart.h"
#include "memory.h"

void main(void) {
    uart_init();

    /* Write stack canary */
    *(volatile uint32_t*)DSTACK_GUARD = STACK_CANARY;

    uart_puts("Hello, Fock\r\n");

    while (1) {
        char c = uart_getc();
        uart_putc(c);
    }
}
