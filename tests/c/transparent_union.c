// EXPECT: 42
// GNU transparent_union (the kernel's release_pages_arg): an argument of any member's type, and the union itself, passed
// as the first member, as gcc passes it
struct page { int n; };
struct folio { struct page p; int extra; };
typedef union {
	struct page **pages;
	struct folio **folios;
	void *raw;
} release_arg __attribute__((__transparent_union__));
__attribute__((noinline)) static int count(release_arg arg, int nr) { int s = 0; for (int i = 0; i < nr; i++) s += arg.pages[i]->n; return s; }
int main(void) {
	struct page a = { 10 }, b = { 12 };
	struct folio c = { { 20 }, 0 };
	struct page *pp[2] = { &a, &b };
	struct folio *fp[1] = { &c };
	release_arg u = { pp };
	return count(pp, 2) + count(fp, 1) + count(u, 1) == 52 ? 42 : 1;
}
