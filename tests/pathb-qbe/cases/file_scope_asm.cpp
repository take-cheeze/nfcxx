// EXPECT: 42
// STDOUT: same
// A file-scope asm block is passed to the object as it is: here it defines a read-only symbol that the C++ code reads
// (the same mechanism defines a .cu's device image). Path B used to drop the block, and the link then had no symbol.
__asm__(
  ".globl nfcxx_file_scope_value\n"
  ".section .rodata\n"
  ".balign 4\n"
  "nfcxx_file_scope_value:\n"
  ".long 42\n"
  ".text\n");
extern "C" const int nfcxx_file_scope_value;
int main() { return nfcxx_file_scope_value; }
