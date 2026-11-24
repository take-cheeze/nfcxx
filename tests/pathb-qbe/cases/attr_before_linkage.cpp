// EXPECT: 0
// A GNU attribute before a linkage specifier (`EXPORT extern "C" ...`) is accepted and applies to the declaration that follows, as
// clang applies it (Lean's own build). EDG's GNU mode rejected it before scripts/edg-patches/0001-gnu-attributes-before-linkage-spec.patch.
// GCC warns that it ignores the attribute here; the probe checks the code runs, not the visibility.
#define EXPORT __attribute__((visibility("default")))

namespace probe {
EXPORT extern "C" int add_one(int x) { return x + 1; }
}

__attribute__((unused)) extern "C" int add_two(int x) { return x + 2; }

int main() { return (probe::add_one(1) == 2 && add_two(1) == 3) ? 0 : 1; }
