/* A boot sector for tests/pathb-i386/realmode.sh: the BIOS loads it at 0x7c00 in real mode; it reads the next NSECT sectors to
   0x7e00 with int $0x13 and enters them (stage2.S). Assembled with `gcc -m32 -c`: .code16 is real mode. */
	.code16
	.text
	.globl _start
_start:
	cli
	xorw %ax, %ax
	movw %ax, %ds
	movw %ax, %es
	movw %ax, %ss
	movw $0x7c00, %sp
	sti
	movw $0x7e00, %bx
	movb $2, %ah
	movb $NSECT, %al
	xorb %ch, %ch
	movb $2, %cl
	xorb %dh, %dh
	/* %dl is the boot drive, as the BIOS left it */
	int $0x13
	jc 1f
	ljmp $0, $0x7e00
1:	movb $1, %al
	movw $0xf4, %dx
	outb %al, %dx
2:	hlt
	jmp 2b
	.org 510
	.word 0xaa55
