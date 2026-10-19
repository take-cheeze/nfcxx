/* Clean-room locale.h: declarations from C11 7.11 (Localization). Written from the standard, not from any SDK.
 * The LC_* values are Apple's, from the public Libc include/locale.h (apple-oss-distributions/Libc commit 71bbe350ab79eef58113991d817ccc6165061a64): LC_ALL 0, LC_COLLATE 1, LC_CTYPE 2, LC_MONETARY 3, LC_NUMERIC 4, LC_TIME 5, LC_MESSAGES 6. */
#ifndef CLEANROOM_LOCALE_H
#define CLEANROOM_LOCALE_H
#ifdef __cplusplus
extern "C" {
#endif

#define LC_ALL 0
#define LC_COLLATE 1
#define LC_CTYPE 2
#define LC_MONETARY 3
#define LC_NUMERIC 4
#define LC_TIME 5
#define LC_MESSAGES 6

struct lconv {
  char *decimal_point;
  char *thousands_sep;
  char *grouping;
  char *int_curr_symbol;
  char *currency_symbol;
  char *mon_decimal_point;
  char *mon_thousands_sep;
  char *mon_grouping;
  char *positive_sign;
  char *negative_sign;
  char int_frac_digits;
  char frac_digits;
  char p_cs_precedes;
  char p_sep_by_space;
  char n_cs_precedes;
  char n_sep_by_space;
  char p_sign_posn;
  char n_sign_posn;
  char int_p_cs_precedes;
  char int_n_cs_precedes;
  char int_p_sep_by_space;
  char int_n_sep_by_space;
  char int_p_sign_posn;
  char int_n_sign_posn;
};

char *setlocale(int category, const char *locale);
struct lconv *localeconv(void);

#ifdef __cplusplus
}
#endif
#endif
