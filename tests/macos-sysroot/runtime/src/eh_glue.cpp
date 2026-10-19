// The EDG exception runtime in libC.a (throw.o, vars.o, vec_newdel.o) calls three names that EDG defines in eh_util.o.
// build.sh leaves eh_util.o out of libC-darwin.a, because it also defines std::terminate, std::unexpected and the handler
// functions that libc++abi now defines. These forward to libc++abi's handlers, so a handler installed with std::set_terminate
// also runs when the EH runtime terminates. This does not reproduce EDG's exception-specification check in __call_unexpected
// (which throws std::bad_exception when the thrown type is not allowed): libc++ calls the unexpected handler and nothing else.
// std::uncaught_exception and std::uncaught_exceptions were eh_util.o's too; they read libc++abi's count.
#include <cstdlib>
#include <exception>

extern "C" {
bool __cxa_uncaught_exception(void) noexcept;
int __cxa_uncaught_exceptions(void) noexcept;

void __call_terminate(void) { std::terminate(); }
void __call_unexpected(void) { std::unexpected(); }
// The initial value of EDG's __default_terminate_routine slot (vars.o). Nothing calls it once std::terminate is libc++abi's.
void __default_terminate(void) { std::abort(); }
}

namespace std {
bool uncaught_exception() noexcept { return __cxa_uncaught_exception(); }
int uncaught_exceptions() noexcept { return __cxa_uncaught_exceptions(); }
}
