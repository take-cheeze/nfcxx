// A long count of 0x100000005 is out of range for a 32-bit shift: it must abort (checked shift), not wrap to 5 when the
// count is narrowed to the operand's width.
// TRAP-EXIT: 134
volatile unsigned long count = 0x100000005UL;
int main() { unsigned x = 1; return (int)(x << count); }
