// EXPECT: 0
// X86-ONLY: the EDG front end on aarch64 rejects a long double literal (x86-64 long double layout), so this case is skipped there
// QBE path (scripts/qbe-prep.rb): global constructors. EDG marks each static initializer with the GNU
// constructor attribute; cproc rejects it, so the QBE output lists the functions in .init_array instead
// (docs/notes/realworld.md, gap 3).
int initial_value() { return 42; }
int g_value = initial_value();

struct Registrar {
    int v;
    Registrar() : v(5) {}
};
Registrar g_registrar;

int main() {
    if (g_value != 42) return 1;
    if (g_registrar.v != 5) return 2;
    return 0;
}
