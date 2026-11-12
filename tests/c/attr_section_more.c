// EXPECT: 42
// ELF-ONLY: an ELF section name (Mach-O wants segment,section)
// GNU section on writable data, const data, a pointer table and an array, in several sections; the entries of one section are
// adjacent, and a writable one is writable.
struct ent { int v; };
static struct ent w1 __attribute__((used, section("nfcxx_w"))) = { 3 };
static struct ent w2 __attribute__((used, section("nfcxx_w"))) = { 4 };
static const int k1 __attribute__((used, section("nfcxx_k"))) = 10;
static const int k2 __attribute__((used, section("nfcxx_k"))) = 20;
static int arr[3] __attribute__((used, section("nfcxx_a"))) = { 1, 2, 3 };
int g_visible __attribute__((section("nfcxx_g"))) = 5;      /* external linkage, and referenced */
extern struct ent __start_nfcxx_w[], __stop_nfcxx_w[];
extern const int __start_nfcxx_k[], __stop_nfcxx_k[];
int main(void) {
	int sw = 0, sk = 0;
	for (struct ent *e = __start_nfcxx_w; e < __stop_nfcxx_w; ++e) { sw += e->v; e->v *= 2; }
	for (const int *p = __start_nfcxx_k; p < __stop_nfcxx_k; ++p) sk += *p;
	if (sw != 7 || sk != 30) return 1;
	if (w1.v != 6 || w2.v != 8) return 2;       /* writable */
	if (arr[0] + arr[1] + arr[2] != 6 || g_visible != 5) return 3;
	return 42;
}
