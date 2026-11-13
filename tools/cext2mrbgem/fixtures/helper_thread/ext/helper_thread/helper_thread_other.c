#include <ruby.h>
#include "helper_thread.h"

/* a registered method in another file calls the header-declared helper */
VALUE ht_other(VALUE self, VALUE s) {
    return ht_wrap(self, s);
}
