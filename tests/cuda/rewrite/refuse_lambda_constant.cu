// A launch argument that is a constexpr local of a generic lambda (decltype(I)::value): not carried, refused by name.
template <int... Ns>
static __global__ void k(int *p) { p[0] = 1; }

static void run(int *p) {
    auto launch = [=](auto I) {
        constexpr int ncols = decltype(I)::value;
        if (ncols > 0) {
            k<ncols><<<1, 1>>>(p);
        }
    };
    launch(0);
}
