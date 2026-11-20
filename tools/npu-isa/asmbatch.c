/* Batch MoviTools assembler: one process, many instructions.
 * Usage: asmbatch.exe <MVC_DEPEND root> <instructions.txt> <out.txt> <target>
 * Each input line is one instruction (or bundle). Output line: "<index>\t<OK|ERR>\t<obj hex>". */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int(__cdecl *assemble_fn)(int, char **, void *, uint32_t, void **, size_t *, void **, size_t *);
typedef void(__cdecl *free_fn)(void);

int main(int argc, char **argv) {
    if (argc < 5) { printf("usage: asmbatch <root> <in.txt> <out.txt> <target>\n"); return 2; }
    char dll[MAX_PATH * 2];
    snprintf(dll, sizeof(dll), "%s\\bin\\moviAsm64.dll", argv[1]);
    HMODULE h = LoadLibraryExA(dll, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    assemble_fn assemble = (assemble_fn)GetProcAddress(h, "process");
    free_fn afree = (free_fn)GetProcAddress(h, "freeResults");
    FILE *in = fopen(argv[2], "r");
    FILE *out = fopen(argv[3], "w");
    if (!in || !out || !assemble || !afree) { printf("setup failed\n"); return 1; }
    char line[1024];
    int index = 0;
    while (fgets(line, sizeof(line), in)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        char src[1400];
        int len = snprintf(src, sizeof(src), ".code .text\n.L.text:\n    generated_0:\n        %s\n.end\n", line);
        char *aargv[] = {"moviAsm.dll", "--cv", argv[4], "--noSPrefixing", NULL};
        void *obj = NULL, *diag = NULL;
        size_t obj_size = 0, diag_size = 0;
        int rc = assemble(4, aargv, src, (uint32_t)len, &obj, &obj_size, &diag, &diag_size);
        if (rc == 0 && obj && obj_size) {
            fprintf(out, "%d\tOK\t", index);
            for (size_t i = 0; i < obj_size; i++) fprintf(out, "%02x", ((unsigned char *)obj)[i]);
            fprintf(out, "\n");
        } else {
            fprintf(out, "%d\tERR\t-\t", index);
            if (diag && diag_size) {
                for (size_t i = 0; i < diag_size && i < 300; i++) {
                    char c = ((char *)diag)[i];
                    fputc((c == '\n' || c == '\r' || c == '\t') ? ' ' : c, out);
                }
            }
            fprintf(out, "\n");
        }
        afree();
        index++;
    }
    fclose(in);
    fclose(out);
    printf("assembled %d lines\n", index);
    return 0;
}
