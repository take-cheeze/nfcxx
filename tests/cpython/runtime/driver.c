/* Runs the lowered module (pyf_0) and prints its global `result` the way the reference prints it with print(): an int in
 * decimal, a bool as True or False, None as None. A module that never binds `result` has no value to print. */
#include <stdint.h>
#include <stdio.h>

#include "pyrt.h"

extern PV pyg_result;

int main(void) {
  PV ret = {0, 0, 0, 0};
  PV args[1] = {{0, 0, 0, 0}};
  pyf_0(&ret, args);
  switch (pyg_result.tag) {
    case PV_INT: printf("%lld\n", (long long)pyg_result.a); break;
    case PV_BOOL: printf("%s\n", pyg_result.a ? "True" : "False"); break;
    case PV_NONE: printf("None\n"); break;
    case PV_UNBOUND:
      fprintf(stderr, "AttributeError: module has no attribute 'result'\n");
      return 1;
    default:
      printf("<function>\n");
      break;
  }
  return 0;
}
