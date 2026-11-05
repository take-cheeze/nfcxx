// A value above the range of the 1-byte integer traps (the IR's checked cf2i).
// TRAP
volatile double d = 128.0;
int main() { return (signed char)d; }
