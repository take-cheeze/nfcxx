/* The first code at 0x7e00: it calls pb_main (a function of the case, in -mregparm=3 convention, built by Path B or by gcc -m16) and
   writes what pb_main returns to the exit device (qemu's isa-debug-exit at port 0xf4: the process status is (value << 1) | 1).
   pb_putc(c) writes a character to qemu's debug console (port 0xe9). .code16gcc: the code the compilers make is 32-bit code with
   size prefixes, so these functions are written in the same dialect (retl, calll). */
	.code16gcc
	.text
	.globl _stage2
_stage2:
	cld
	calll pb_main
	movw $0xf4, %dx
	outb %al, %dx
1:	hlt
	jmp 1b

	.globl pb_putc
pb_putc:
	movw $0xe9, %dx
	outb %al, %dx
	retl
