/* Runs the lowered main function (sq_fn_0) and prints its result the way tests/squirrelbc/oracle/sqref.c does: an integer
 * as %lld, a boolean as true or false, null as null, a string as its text, one line. The stack has 4096 values, zeroed;
 * the root table is the `this` of the main function (sqbc_rt_init). */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include "sqbcrt.h"

#define STACK_SLOTS 4096

int main(void) {
  SQV ret;
  SQV *base = calloc(STACK_SLOTS, sizeof(SQV));
  if (!base) return 1;
  sqbc_rt_init(base, STACK_SLOTS);
  ret.tag = SQBC_TAG_NULL;
  ret.pad = 0;
  ret.i = 0;
  sq_fn_0(&ret, base, NULL);
  switch (ret.tag) {
    case SQBC_TAG_INTEGER: printf("%" PRId64 "\n", ret.i); break;
    case SQBC_TAG_BOOL: printf("%s\n", ret.i ? "true" : "false"); break;
    case SQBC_TAG_NULL: printf("null\n"); break;
    case SQBC_TAG_STRING: printf("%s\n", sqbc_rt_text(&ret)); break;
    default: printf("(not printed: tag 0x%08x)\n", (unsigned)ret.tag); break;
  }
  return 0;
}
