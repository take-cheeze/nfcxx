/* The static variant of nfcxx_alloc.c (scripts/nfcxx-loop.rb, --profile with -static): the same counting, under the __wrap_
 * names, which the link takes with -Wl,--wrap=malloc,... so that libc.a's own calls to malloc are counted too. */
#define NFCXX_ALLOC_WRAP 1
#include "nfcxx_alloc.c"
