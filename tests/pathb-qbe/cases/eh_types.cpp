// EXPECT: 0
// C++ exceptions, part 6 (Path B): which handler a thrown type selects. Exact fundamental types (no integral
// conversion between them), cv and pointer conversions, an enum, a function pointer, nullptr, arrays inside
// classes, lambdas and templates that throw or catch. The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)

// The handler list is tried in order; the result names the first one that matches.
#define PICK(THROWN) \
  try { THROWN; } \
  catch (bool) { return 1; } catch (char) { return 2; } catch (signed char) { return 3; } \
  catch (unsigned char) { return 4; } catch (short) { return 5; } catch (unsigned short) { return 6; } \
  catch (int) { return 7; } catch (unsigned) { return 8; } catch (long) { return 9; } \
  catch (unsigned long) { return 10; } catch (long long) { return 11; } catch (unsigned long long) { return 12; } \
  catch (float) { return 13; } catch (double) { return 14; } \
  catch (const char *) { return 16; } catch (void *) { return 17; } catch (...) { return 99; } \
  return 0;

enum Color { Red, Green };
enum class Shade : short { Dark, Light };
static int pick_bool() { PICK(throw true) }
static int pick_char() { PICK(throw 'a') }
static int pick_schar() { PICK(throw (signed char)1) }
static int pick_uchar() { PICK(throw (unsigned char)1) }
static int pick_short() { PICK(throw (short)1) }
static int pick_ushort() { PICK(throw (unsigned short)1) }
static int pick_int() { PICK(throw 1) }
static int pick_uint() { PICK(throw 1u) }
static int pick_long() { PICK(throw 1L) }
static int pick_ulong() { PICK(throw 1UL) }
static int pick_ll() { PICK(throw 1LL) }
static int pick_ull() { PICK(throw 1ULL) }
static int pick_float() { PICK(throw 1.0f) }
static int pick_double() { PICK(throw 1.0) }
static int pick_cstr() { PICK(throw "abc") }
static int pick_enum() { PICK(throw Green) }        // an enum is not int: catch (...)
static int pick_eclass() { PICK(throw Shade::Light) }
static int pick_voidp() { int x; PICK(throw (void *)&x) }
static int pick_intp() { int x; PICK(throw &x) }    // int * -> void * is a valid handler match
static int pick_null() { PICK(throw nullptr) }      // nullptr_t matches the first pointer handler (const char *)

static int sel_enum() { try { throw Green; } catch (Color c) { return 10 + (int)c; } catch (...) { return 0; } }
static int sel_shade() { try { throw Shade::Light; } catch (Shade s) { return 20 + (int)s; } catch (...) { return 0; } }
static void fn() {}
static int sel_fnptr() { try { throw &fn; } catch (void (*p)()) { p(); return 1; } catch (...) { return 0; } }
static int sel_cv() { int v = 5; try { throw &v; } catch (const int *p) { return *p; } catch (...) { return 0; } }
static int sel_ptrptr() { int v = 5; int *p = &v; try { throw &p; } catch (int **q) { return **q; } catch (...) { return 0; } }

struct WithArray { int a[4]; int i; };
static int sel_array() { WithArray w = {{1, 2, 3, 4}, 7}; try { throw w; } catch (WithArray x) { return x.a[3] * 10 + x.i; } return 0; }

template <class T> static int roundtrip(T v) { try { throw v; } catch (T w) { return w == v; } catch (...) { return 0; } }
template <class T> struct Holder { T t; };
template <class T> static int holder(T v) { try { throw Holder<T>{v}; } catch (Holder<T> &h) { return h.t == v; } catch (...) { return 0; } }

static int lambda_throw() {
  auto thrower = [](int x) { if (x) throw x; return 0; };
  int r = 0;
  try { r = thrower(0); r += thrower(9); } catch (int e) { r += e * 10; }
  return r;
}
static int lambda_catch() {
  auto safe = [](int x) { try { throw x; } catch (int e) { return e + 1; } };
  return safe(4);
}
static int capture_state() {
  int count = 0;
  auto f = [&](int x) { try { if (x & 1) throw x; ++count; } catch (int) { count += 10; } };
  for (int i = 0; i < 4; i++) f(i);
  return count;
}

int main() {
  CHECK(pick_bool() == 1); CHECK(pick_char() == 2); CHECK(pick_schar() == 3); CHECK(pick_uchar() == 4);
  CHECK(pick_short() == 5); CHECK(pick_ushort() == 6); CHECK(pick_int() == 7); CHECK(pick_uint() == 8);
  CHECK(pick_long() == 9); CHECK(pick_ulong() == 10); CHECK(pick_ll() == 11); CHECK(pick_ull() == 12);
  CHECK(pick_float() == 13); CHECK(pick_double() == 14);
  CHECK(pick_cstr() == 16);
  CHECK(pick_enum() == 99); CHECK(pick_eclass() == 99);
  CHECK(pick_voidp() == 17); CHECK(pick_intp() == 17);
  CHECK(pick_null() == 16);
  CHECK(sel_enum() == 11); CHECK(sel_shade() == 21);
  CHECK(sel_fnptr() == 1); CHECK(sel_cv() == 5); CHECK(sel_ptrptr() == 5);
  CHECK(sel_array() == 47);
  CHECK(roundtrip(3) && roundtrip(3L) && roundtrip(3.5) && roundtrip('c') && roundtrip(true));
  CHECK(holder(3) && holder(2.5) && holder<long>(8));
  CHECK(lambda_throw() == 90); CHECK(lambda_catch() == 5); CHECK(capture_state() == 22);
  return bad;
}
