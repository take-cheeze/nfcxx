/*
 * langinfo.h for the clean-room macOS sysroot, written from POSIX.1-2008 <langinfo.h>: nl_langinfo and the CODESET item.
 * CODESET is item 0 on the target: in a UTF-8 locale nl_langinfo(0) returns "UTF-8" (checked on the Mac).
 */
#ifndef NFCXX_CLEANROOM_LANGINFO_H
#define NFCXX_CLEANROOM_LANGINFO_H

#include <nl_types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CODESET 0

char *nl_langinfo(nl_item);

#ifdef __cplusplus
}
#endif

#endif /* NFCXX_CLEANROOM_LANGINFO_H */
