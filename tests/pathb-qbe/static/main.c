int a_val(int x);
int b_val(int x);
int main(void) { return a_val(10) == 11 && b_val(10) == 20 ? 0 : 1; }
