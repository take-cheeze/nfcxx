// EXPECT: 0
// QBE path (scripts/qbe-prep.rb): GNU aligned on members and struct bodies, __bf16 and the _Float types of <numbers>,
// and thread_local with dynamic initialization. cproc rejects each of these forms in EDG's C output (docs/notes/realworld.md).
#include <cstdint>
#include <numbers>  // std::numbers variables use _Float16/_Float32/_Float64/_Float128

struct Member {
    unsigned char storage[40] __attribute__((aligned(8)));
    int tag;
};
struct Body {
    char dummy[8];
} __attribute__((aligned(8)));
typedef __bf16 bf16_t;

int initial() { return 7; }
thread_local int tl = initial();

static bool aligned_to(const void *p, std::uintptr_t n) { return reinterpret_cast<std::uintptr_t>(p) % n == 0; }

int main() {
    Member m{};
    Body b{};
    if (!aligned_to(m.storage, 8) || !aligned_to(&b, 8)) return 1;
    if (sizeof(Body) != 8 || sizeof(bf16_t) != 2) return 2;
    if (!(std::numbers::pi_v<double> > 3.0)) return 5;
    return tl == 7 ? 0 : 4;
}
