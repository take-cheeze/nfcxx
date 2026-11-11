// The C side of the astro backend (nfcpoly_astro_shim.c): the part of ASTro's sample/luastro that nfcpoly needs, behind plain C.
// luastro has a CLI main() and no embedding API, so scripts/setup-poly-astro.sh compiles the shim, which includes luastro's own
// sources the way its main.c does, next to the generated evaluator and puts the result in libluastro.a. A value is luastro's
// LuaValue (a tagged 64-bit word: nil, boolean, 63-bit integer, double, or a pointer to a string / table / function).
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t nfc_lv;

enum { NFC_NIL, NFC_BOOL, NFC_INT, NFC_FLOAT, NFC_STR, NFC_TABLE, NFC_FUNC, NFC_THREAD, NFC_OTHER };

// What a bound host function is called through: ID is the number it was registered under (the first argument of the script's
// call to __nfc_call), ARGS the script's arguments. Returns 0 with *OUT the result, or nonzero with *OUT the script error value
// to raise. Must not throw or longjmp.
typedef int (*nfc_host_fn)(void* user, long id, const nfc_lv* args, unsigned argc, nfc_lv* out);

// luastro keeps its interpreter in process globals (the interned names, the object list): one open interpreter at a time.
// open returns -1 when one is open; close ends it (the next open starts from fresh globals).
int nfc_ls_open(nfc_host_fn fn, void* user);
void nfc_ls_close(void);

// Runs SRC as a chunk. 0 ok, *OUT its first result; 1 syntax error, *OUT the message (a string); 2 a script error, *OUT its value.
int nfc_ls_eval(const char* src, size_t len, nfc_lv* out);
// Calls the function F with ARGS. 0 ok / 2 error, as above.
int nfc_ls_call(nfc_lv f, const nfc_lv* args, unsigned argc, nfc_lv* out);
// target[name](target, args...) with the __index chain of tables and the string library for strings. 0 / 2 as above; 3 no such method.
int nfc_ls_call_method(nfc_lv target, const char* name, size_t nlen, const nfc_lv* args, unsigned argc, nfc_lv* out);

int nfc_ls_kind(nfc_lv v);
int nfc_ls_int_fits(long long i);  // luastro integers have 63 bits
nfc_lv nfc_ls_mk_bool(int b);
nfc_lv nfc_ls_mk_int(long long i);
nfc_lv nfc_ls_mk_float(double d);
nfc_lv nfc_ls_mk_str(const char* s, size_t n);
nfc_lv nfc_ls_mk_table(unsigned narr, unsigned nhash);
int nfc_ls_as_bool(nfc_lv v);
long long nfc_ls_as_int(nfc_lv v);
double nfc_ls_as_float(nfc_lv v);
const char* nfc_ls_str_data(nfc_lv v);
size_t nfc_ls_str_len(nfc_lv v);
// A string describing V (what tostring gives).
nfc_lv nfc_ls_tostring(nfc_lv v);

void nfc_ls_table_seti(nfc_lv t, long long i, nfc_lv v);
nfc_lv nfc_ls_table_geti(nfc_lv t, long long i);
void nfc_ls_table_set_str(nfc_lv t, const char* name, nfc_lv v);
nfc_lv nfc_ls_table_get_str(nfc_lv t, const char* name);
long long nfc_ls_table_len(nfc_lv t);  // the length of the array part
// Iteration: start with *K = nil; returns 0 at the end.
int nfc_ls_table_next(nfc_lv t, nfc_lv* k, nfc_lv* v);
// 1 when T holds exactly the keys 1..n (n may be 0).
int nfc_ls_table_is_array(nfc_lv t);

void nfc_ls_set_global(const char* name, nfc_lv v);
nfc_lv nfc_ls_get_global(const char* name);
// Roots: ID keeps V alive (nil drops it). luastro's collector runs only when a script calls collectgarbage.
void nfc_ls_root_set(long id, nfc_lv v);
nfc_lv nfc_ls_root_get(long id);
void nfc_ls_collect(void);

#ifdef __cplusplus
}
#endif
