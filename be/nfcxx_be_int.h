/*
nfcxx_be_int.h -- declarations shared by the Path B back ends in be/: the IL dump (nfcxx_be.c) and the
mid-level IR (nfcxx_ir.c). Include only after the EDG headers and USING_NAMESPACE_EDG.
*/

#ifndef NFCXX_BE_INT_H
#define NFCXX_BE_INT_H

#include <stddef.h>
#include <stdio.h>

/* Output stream of the printers below (stdout, or a buffer while a back end captures text). */
extern FILE *nf_out;

/* Printers from nfcxx_be.c. They write to nf_out. */
extern int nf_ld_blob;   /* IR mode: print long double as (array 16 unsigned_char) */
void nf_put_atom(const char *s);
void nf_put_quoted(const char *s, size_t len);
void nf_put_unqualified_type(a_type_ptr type);
void nf_put_type(a_type_ptr type);
void nf_put_constant(a_constant_ptr constant);

/* The mid-level IR back end (nfcxx_ir.c), selected by NFCXX_PATHB_MODE=ir. */
void nfcxx_ir_back_end(void);

#endif /* NFCXX_BE_INT_H */
