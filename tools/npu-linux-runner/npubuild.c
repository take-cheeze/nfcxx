/* npubuild.exe: compile, assemble and link SHAVE kernels with the MoviTools DLLs.
 *
 * Run under wine from a directory that holds the MoviTools bin/ directory. Each mode mirrors one step of
 * tools/build_ptl_kernel.py (flags, target and linker script are the pinned ones):
 *
 *   npubuild.exe compile  <root> <entry.c> <out.s> <diag>  compile C (SHAVE, -O2, pinned cc1 flags)
 *   npubuild.exe asm      <root> <in.s> <out.o> <diag>  assemble to an ELF32 relocatable object
 *   npubuild.exe link     <root> <in.o> <out.elf> <entry>  link with the pinned SHAVE script
 *
 * <root> is the MoviTools MVC_DEPEND directory (contains bin/moviCompile64.dll etc.).
 * Exit status is 0 on success; diagnostics go to the named file or stdout.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int(__cdecl *compile_fn)(int, char **, void *, size_t, void **, size_t *, void **, size_t *);
typedef int(__cdecl *asm_fn)(int, char **, void *, uint32_t, void **, size_t *, void **, size_t *);
typedef int(__cdecl *link_fn)(int, char **, void *, void *);
typedef void(__cdecl *free_fn)(void);

struct Buffer { void *data; size_t size; };
struct Buffers { struct Buffer *items; size_t count; };

static void *slurp(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    long n;
    void *b;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    b = calloc(1, (size_t)n + 1);
    if (b && n > 0) fread(b, 1, (size_t)n, f);
    fclose(f);
    *size = (size_t)n;
    return b;
}

static void spit(const char *path, const void *data, size_t size) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    if (size) fwrite(data, 1, size, f);
    fclose(f);
}

static HMODULE load(const char *root, const char *name) {
    char path[1024];
    snprintf(path, sizeof path, "%s\\bin\\%s", root, name);
    return LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}

int main(int argc, char **argv) {
    const char *mode, *root;
    if (argc < 4) { fprintf(stderr, "usage: npubuild.exe <mode> <root> ...\n"); return 2; }
    mode = argv[1];
    root = argv[2];

    if (!strcmp(mode, "compile") && argc >= 5) {
        size_t n = 0;
        void *src = slurp(argv[3], &n);
        HMODULE h = load(root, "moviCompile64.dll");
        compile_fn compile;
        free_fn release;
        char *cargv[] = {"moviCompile.dll", "-cc1", "-triple", "shave", "-target-cpu", "5000xx", "-S", "-O2",
                         "-fno-jump-tables", "-ffp-contract=off", "-DNR_SHAVE=1", "-x", "c", "entry.c",
                         "-ffunction-sections", "-fdata-sections", "-o", "-", NULL};
        void *out = NULL, *diag = NULL;
        size_t osz = 0, dsz = 0;
        int rc;
        if (!src || !h) return 3;
        compile = (compile_fn)GetProcAddress(h, "main");
        release = (free_fn)GetProcAddress(h, "freeResults");
        if (!compile || !release) return 4;
        rc = compile((int)(sizeof cargv / sizeof cargv[0]) - 1, cargv, src, n, &out, &osz, &diag, &dsz);
        if (diag && dsz && argc >= 6) spit(argv[5], diag, dsz);
        if (!rc && out && osz) spit(argv[4], out, osz);
        if (rc) { release(); return 1; }
        release();
        return 0;
    }

    if (!strcmp(mode, "asm") && argc >= 6) {
        size_t n = 0;
        void *src = slurp(argv[3], &n);
        HMODULE h = load(root, "moviAsm64.dll");
        asm_fn process;
        free_fn release;
        char *aargv[] = {"moviAsm.dll", "--cv", "5000xx", "--noSPrefixing", NULL};
        void *obj = NULL, *diag = NULL;
        size_t osz = 0, dsz = 0;
        int rc;
        if (!src || !h) return 3;
        process = (asm_fn)GetProcAddress(h, "process");
        release = (free_fn)GetProcAddress(h, "freeResults");
        if (!process || !release) return 4;
        rc = process(4, aargv, src, (uint32_t)n, &obj, &osz, &diag, &dsz);
        if (argc >= 6) spit(argv[5], diag ? diag : "", diag ? dsz : 0);
        if (!rc && obj && osz) spit(argv[4], obj, osz);
        release();
        return rc ? 1 : 0;
    }

    if (!strcmp(mode, "link") && argc >= 6) {
        size_t on = 0;
        void *obj = slurp(argv[3], &on);
        const char *script =
            "OUTPUT_FORMAT(\"elf32-sparc\")\nOUTPUT_ARCH(sparc)\n"
            "SECTIONS { . = 0x1e000000; .arg.data : { *(.arg.data) *(.data*) . = ALIGN(16); } "
            ". = 0x1d000000; .text : { *(.text*) . = ALIGN(16); *(.rodata*) . = ALIGN(16); } }\n";
        HMODULE h = load(root, "moviLLD64.dll");
        link_fn process;
        free_fn release;
        struct Buffer items[2];
        struct Buffers inputs[8];
        struct Buffer outputs[8];
        char *largv[] = {"moviLLD.dll", "-flavor", "gnu", "-EL", "-e", argv[5], "-z", "max-page-size=0x10",
                         "--gc-sections", NULL};
        int rc;
        if (!obj || !h) return 3;
        process = (link_fn)GetProcAddress(h, "process");
        release = (free_fn)GetProcAddress(h, "freeResults");
        if (!process || !release) return 4;
        items[0].data = obj; items[0].size = on;
        items[1].data = (void *)script; items[1].size = strlen(script);
        memset(inputs, 0, sizeof inputs);
        memset(outputs, 0, sizeof outputs);
        inputs[0].items = items;
        inputs[0].count = 2;
        rc = process(9, largv, inputs, outputs);
        if (!rc && outputs[0].data && outputs[0].size) spit(argv[4], outputs[0].data, outputs[0].size);
        release();
        return rc ? 1 : 0;
    }

    fprintf(stderr, "bad mode or arguments\n");
    return 2;
}
