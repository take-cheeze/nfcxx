// EXPECT-REFUSED: aligned to 4096
struct s { char b[64]; } __attribute__((aligned(4096))) backing;
int main(void) { return ((unsigned long)&backing % 4096) != 0; }
