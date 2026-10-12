// ASAN: global-buffer-overflow
// ASAN-QBE: use-after-poison   (qbe poisons its redzones with __asan_poison_memory_region, see stack_overflow.cpp)
int table[8] = {1, 2, 3, 4, 5, 6, 7, 8};
int at(int i) { return table[i]; }
int main(int argc, char **) { return at(8 + argc); }
