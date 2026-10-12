// ASAN: global-buffer-overflow
// ASAN-ONLY: gcc   (qbe has no redzones for globals or stack yet: asan-plan.md, milestones 3-4)
int table[8] = {1, 2, 3, 4, 5, 6, 7, 8};
int at(int i) { return table[i]; }
int main(int argc, char **) { return at(8 + argc); }
