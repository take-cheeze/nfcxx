# ESP32-C3 bare-metal start for the QEMU run (tests/mcu/run.sh). The program is loaded with `qemu-system-riscv32 -M esp32c3
# -kernel` (Espressif's QEMU fork), which skips the ROM. _start sets the stack, zeroes .bss, calls nfcxx_mcu_run() and exits
# through RISC-V semihosting with its return value as the exit status. QEMU's 32-bit SYS_EXIT (0x18) only reports 0 or 1,
# so this uses SYS_EXIT_EXTENDED (0x20): a parameter block {ADP_Stopped_ApplicationExit, status}, after the
# slli/ebreak/srai sequence that QEMU recognises.
    .section .text.init, "ax", @progbits
    .globl _start
_start:
    la sp, _stack_top
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call nfcxx_mcu_run
    la t0, exit_block
    li t1, 0x20026                  # ADP_Stopped_ApplicationExit
    sw t1, 0(t0)
    sw a0, 4(t0)
    li a0, 0x20                     # SYS_EXIT_EXTENDED
    mv a1, t0
    .option push
    .option norvc
    slli zero, zero, 0x1f
    ebreak
    srai zero, zero, 7
    .option pop
3:  j 3b

    .section .data, "aw", @progbits
    .balign 8
exit_block:
    .word 0, 0
