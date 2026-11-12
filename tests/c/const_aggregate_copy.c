/* EXPECT: 0
   Path B: a const object of struct type with a constant initializer is folded by the front end into an aggregate constant
   where it is copied (sqlite's `static const struct ExprList_item zeroItem = {0}; ... *pItem = zeroItem;`). The lowering
   had no form for the value ("unsupported const aggregate", the function was not emitted); it now reads a read-only
   global of its own. */
typedef struct { void *expr; char *name; int a, b; unsigned char flag; } Item;

static const Item zero = {0};
static const Item seed = {0, 0, 7, 9, 3};

__attribute__((noinline)) static void reset(Item *p) { *p = zero; }
__attribute__((noinline)) static void init(Item *p) { *p = seed; }

int main(void) {
  Item it;
  init(&it);
  if (it.a != 7 || it.b != 9 || it.flag != 3) return 1;
  reset(&it);
  if (it.a != 0 || it.b != 0 || it.flag != 0 || it.expr != 0) return 2;
  return 0;
}
