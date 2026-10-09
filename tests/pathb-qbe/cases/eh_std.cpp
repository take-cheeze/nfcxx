// EXPECT: 0
// C++ exceptions, part 8 (Path B): library exception types of the headers the harness has (<exception>, <typeinfo>):
// a class derived from std::exception caught as std::exception &, std::bad_typeid from typeid of a null pointer,
// std::bad_cast from a failed dynamic_cast to a reference. (<new> and the full <stdexcept> are not available to the
// harness: no C library headers, see docs/notes/pathb-stage3.md.) The exit code is the number of wrong results.
#include <exception>
#include <typeinfo>
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)
struct A { virtual ~A() {} };
struct B : A {};
struct MyErr : std::exception { const char *what() const noexcept override { return "my"; } };
static int my_err() { try { throw MyErr(); } catch (const std::exception &e) { return e.what()[0] == 'm' ? 1 : 0; } return 2; }
static int bad_typeid() { A *p = nullptr; try { (void)typeid(*p); } catch (std::bad_typeid &) { return 1; } catch (...) { return 2; } return 0; }
static int bad_cast() { A a; try { (void)dynamic_cast<B &>(a); } catch (std::bad_cast &) { return 1; } catch (...) { return 2; } return 0; }
static int bad_cast_base() { A a; try { (void)dynamic_cast<B &>(a); } catch (std::exception &) { return 1; } catch (...) { return 2; } return 0; }
static int tid() { B b; A &r = b; return typeid(r) == typeid(B) && typeid(r) != typeid(A); }
int main() {
  CHECK(my_err() == 1); CHECK(bad_typeid() == 1); CHECK(bad_cast() == 1); CHECK(bad_cast_base() == 1); CHECK(tid());
  return bad;
}
