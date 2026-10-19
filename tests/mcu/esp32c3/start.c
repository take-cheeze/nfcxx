/* ESP32-C3 UART0 output for the QEMU run (tests/mcu/run.sh). The TX FIFO is the first word of UART0 (DR_REG_UART_BASE,
   0x60000000, include/hw/misc/esp32c3_reg.h in Espressif's QEMU). The emulated UART takes a byte per write. */
#include <stdint.h>

#define UART0_FIFO ((volatile uint32_t *)0x60000000u)

void nfcxx_mcu_putc(char c) { *UART0_FIFO = (uint32_t)(unsigned char)c; }
