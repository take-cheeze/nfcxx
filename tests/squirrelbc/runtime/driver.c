/* Runs the lowered main function (sq_fn_0) and prints its result the way tests/squirrelbc/oracle/sqref.c does: an integer
 * as %lld, a boolean as true or false, null as null, one line. The frame has 256 registers (MAX_FUNC_STACKSIZE is 0xFF in
 * sqopcodes.h), zeroed. */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include "sqbcrt.h"

int main(void) {
  SQV ret;
  SQV *base = calloc(256, sizeof(SQV));
  if (!base) return 1;
  ret.tag = SQBC_TAG_NULL;
  ret.pad = 0;
  ret.i = 0;
  sq_fn_0(&ret, base);
  switch (ret.tag) {
    case SQBC_TAG_INTEGER: printf("%" PRId64 "\n", ret.i); break;
    case SQBC_TAG_BOOL: printf("%s\n", ret.i ? "true" : "false"); break;
    case SQBC_TAG_NULL: printf("null\n"); break;
    default: printf("(not printed: tag 0x%08x)\n", (unsigned)ret.tag); break;
  }
  return 0;
}
