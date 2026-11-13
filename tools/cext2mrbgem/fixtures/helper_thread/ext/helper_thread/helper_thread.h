#ifndef HELPER_THREAD_H
#define HELPER_THREAD_H
#include <ruby.h>

/* Helpers declared in the header: the declarations are threaded with the definitions. */
VALUE ht_wrap(VALUE self, VALUE s);
VALUE ht_other(VALUE self, VALUE s);

#endif
