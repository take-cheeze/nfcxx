// EXPECT: 0
// X86-ONLY: __builtin_ia32_pause is the x86 spin-wait hint (CoreCLR's YieldProcessor on x86-64); the QBE path maps it to
// an empty helper (scripts/qbe-prep.rb).
int main() {
    __builtin_ia32_pause();
    return 0;
}
