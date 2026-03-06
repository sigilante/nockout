#include <stdint.h>
#include "uart.h"
#include "memory.h"

extern void forth_main(void);

void main(void) {
    uart_init();

    /* Write stack canary */
    *(volatile uint32_t*)DSTACK_GUARD = STACK_CANARY;

    forth_main();   /* never returns */
}
