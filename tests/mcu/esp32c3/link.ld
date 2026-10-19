/* ESP32-C3 memory map for the QEMU run (Espressif's hw/riscv/esp32c3.c): code in internal SRAM (IRAM, 0x4037c000), data,
   bss and stack in DRAM (0x3fc80000). Both are plain RAM for a program loaded with -kernel, so no flash image is needed. */
ENTRY(_start)

MEMORY
{
  IRAM (rwx) : ORIGIN = 0x4037c000, LENGTH = 0x64000
  DRAM (rw)  : ORIGIN = 0x3fc80000, LENGTH = 0x60000
}

SECTIONS
{
  .text : { KEEP(*(.text.init)) *(.text .text.*) } > IRAM
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > DRAM
  .data : { *(.data .data.*) *(.sdata .sdata.*) } > DRAM
  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    _bss_end = .;
  } > DRAM
  .stack (NOLOAD) : {
    . = ALIGN(16);
    . += 0x4000;
    _stack_top = .;
  } > DRAM
  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
