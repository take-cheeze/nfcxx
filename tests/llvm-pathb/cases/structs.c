// EXPECT: 124
// Structs: field addresses (getelementptr with struct indices), nested and packed layouts, an array of structs, struct
// constants in globals (pointers and bytes inside), and memcpy of a whole struct.
struct inner { char tag; double weight; };
struct outer { int id; struct inner in; short code[3]; };
struct __attribute__((packed)) pk { char c; int i; };
struct named { const char *name; long len; };

static struct named names[] = { { "one", 3 }, { "three", 5 }, { "seven", 5 } };
static struct pk packed = { 'x', 1000 };

static long total_len(void) {
  long n = 0;
  for (int i = 0; i < 3; i++) n += names[i].len + names[i].name[0];
  return n;
}

int main(void) {
  struct outer a = { 7, { 'k', 2.5 }, { 1, 2, 3 } };
  struct outer b;
  __builtin_memcpy(&b, &a, sizeof a);
  b.code[2] = 40;
  int s = b.id + (int)(b.in.weight * 2) + b.code[0] + b.code[2] + (b.in.tag == 'k');
  return s + (int)(total_len() % 100) + packed.i / 100 + (int)sizeof(struct pk);
}
