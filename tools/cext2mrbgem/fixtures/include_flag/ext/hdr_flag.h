#ifndef HDR_FLAG_H
#define HDR_FLAG_H
/* a header one level above the extension directory (json's ext/json.h): read only with --header ../hdr_flag.h */
#include <ruby.h>
#define HDR_FLAG_ANSWER 42
static inline VALUE hdr_flag_value(void) {
    return INT2FIX(HDR_FLAG_ANSWER);
}
#endif
