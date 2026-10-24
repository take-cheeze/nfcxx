// EXPECT: 42
// GNU statement expressions: the statements run where and when the expression is evaluated (not in an untaken operand of
// && || ?:, nor under sizeof/typeof); nesting, loops inside, struct and void values (docs/notes/cproc-nfcxx.md)
#define min(a, b) ({ __typeof__(a) _a = (a); __typeof__(b) _b = (b); _a < _b ? _a : _b; })
struct pt { int x, y; };
static int calls;
static int bump(void) { return ++calls; }
static int *nullp;
int main(void) {
	int a = 7, b = 3;
	if (min(a, b) != 3) return 1;                          /* the basic macro */
	if (min(min(a, 9), min(5, b)) != 3) return 2;          /* nested */
	int r = 0 && ({ *nullp; });                            /* not evaluated under && */
	r += 1 || ({ *nullp; });                               /* nor under || */
	r += a > 0 ? 10 : ({ *nullp; });                       /* nor in the ?: arm not taken */
	if (r != 11) return 3;
	(void)sizeof(({ bump(); }));                           /* not evaluated under sizeof */
	__typeof__(({ bump(); 1; })) t = 5;                    /* nor under typeof */
	if (calls != 0 || t != 5) return 4;
	int s = ({ int acc = 0; for (int i = 0; i < 5; i++) acc += i; acc; });   /* loops inside */
	if (s != 10) return 5;
	struct pt p = ({ struct pt q = { 1, 2 }; q; });        /* struct value */
	if (p.x + p.y != 3) return 6;
	({ bump(); });                                         /* void, as a statement */
	int k = ({ bump(); bump(); }) + ({ 100; });            /* two in one expression */
	if (k != 103 || calls != 3) return 7;
	return 42;
}
