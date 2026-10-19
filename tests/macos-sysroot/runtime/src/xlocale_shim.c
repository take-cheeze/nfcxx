/*
 * The locale-taking wide-character functions libc++ calls (wcscoll_l, wcsxfrm_l, iswupper_l, iswspace_l, iswprint_l).
 * They are the xlocale extension, not POSIX. Each one switches the calling thread to the given locale with uselocale
 * (POSIX.1-2008), calls the POSIX function, and switches back, which is the same behaviour.
 */
#include <locale.h>
#include <wchar.h>
#include <wctype.h>
#include <xlocale.h>

static locale_t nfcxx_use(locale_t l, locale_t *old) {
  *old = uselocale(l);
  return *old;
}

int wcscoll_l(const wchar_t *a, const wchar_t *b, locale_t l) {
  locale_t old;
  nfcxx_use(l, &old);
  int r = wcscoll(a, b);
  uselocale(old);
  return r;
}

size_t wcsxfrm_l(wchar_t *restrict dst, const wchar_t *restrict src, size_t n, locale_t l) {
  locale_t old;
  nfcxx_use(l, &old);
  size_t r = wcsxfrm(dst, src, n);
  uselocale(old);
  return r;
}

int iswupper_l(wint_t c, locale_t l) {
  locale_t old;
  nfcxx_use(l, &old);
  int r = iswupper(c);
  uselocale(old);
  return r;
}

int iswspace_l(wint_t c, locale_t l) {
  locale_t old;
  nfcxx_use(l, &old);
  int r = iswspace(c);
  uselocale(old);
  return r;
}

int iswprint_l(wint_t c, locale_t l) {
  locale_t old;
  nfcxx_use(l, &old);
  int r = iswprint(c);
  uselocale(old);
  return r;
}
