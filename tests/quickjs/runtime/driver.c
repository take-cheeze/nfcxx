/* Runs the lowered script (qjf_0) and prints its global `result` the way the reference prints it with console.log: an int in
 * decimal, a bool as true or false, undefined and null by name. A script that never binds `result` prints undefined. */
#include <stdio.h>

#include "qjrt.h"

extern void qjf_0(JV *ret, JV *args);
extern JV qjg_result;

int main(void) {
  JV ret = {0, 0};
  JV args[1] = {{0, 0}};
  qjf_0(&ret, args);
  switch (qjg_result.tag) {
    case QJRT_INT: printf("%lld\n", (long long)qjg_result.val); break;
    case QJRT_BOOL: printf("%s\n", qjg_result.val ? "true" : "false"); break;
    case QJRT_NULL: printf("null\n"); break;
    case QJRT_UNDEF: printf("undefined\n"); break;
    default: printf("<uninitialized>\n"); break;
  }
  return 0;
}
