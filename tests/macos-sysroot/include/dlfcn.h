/* dlfcn.h: the dynamic linking interface (POSIX.1-2008 dlopen, dlsym, dlclose, dlerror), for the clean-room sysroot.
 * Written from the POSIX specification. The RTLD_* values are the ones this sysroot defines for its own use; they are not
 * read from any SDK. The EH shim needs only RTLD_NEXT and dlsym. */
#ifndef NFCXX_CLEANROOM_DLFCN_H
#define NFCXX_CLEANROOM_DLFCN_H

#ifdef __cplusplus
extern "C" {
#endif

#define RTLD_LAZY 0x1
#define RTLD_NOW 0x2
#define RTLD_GLOBAL 0x8
#define RTLD_LOCAL 0x4
#define RTLD_NEXT ((void *)-1)
#define RTLD_DEFAULT ((void *)-2)

void *dlopen(const char *file, int mode);
void *dlsym(void *handle, const char *symbol);
int dlclose(void *handle);
char *dlerror(void);

/* dladdr (a Darwin and glibc extension, not POSIX), from the dladdr(3) description: the image and nearest symbol of an address. */
typedef struct dl_info {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;
int dladdr(const void *addr, Dl_info *info);

#ifdef __cplusplus
}
#endif

#endif /* NFCXX_CLEANROOM_DLFCN_H */
