// A negative value (the truncation is -1 or less) for an unsigned 1-byte integer traps.
// TRAP
volatile double d = -1.0;
int main() { return (unsigned char)d; }
