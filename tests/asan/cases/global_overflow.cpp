// ASAN: global-buffer-overflow
// ASAN-PATHB: use-after-poison   (the same: the redzone after a global is poisoned at startup, see asan.md)
int table[8] = {1, 2, 3, 4, 5, 6, 7, 8};
int at(int i) { return table[i]; }
int main(int argc, char **) { return at(8 + argc); }
