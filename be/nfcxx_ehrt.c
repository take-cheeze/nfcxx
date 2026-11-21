/* nfcxx Path B zero-cost exception handling runtime (docs/notes/pathb-zero-cost-eh.md). The landing pads of Path B's
   exception tables (QBE's ehpad) cannot read the registers a personality sets for them, so the personality keeps the
   exception and the selector here, and the pad reads them first thing (nothing between can throw). */
#include <stdint.h>
#include <unwind.h>

_Unwind_Reason_Code __gxx_personality_v0(int, _Unwind_Action, _Unwind_Exception_Class, struct _Unwind_Exception *,
                                         struct _Unwind_Context *);

static __thread struct _Unwind_Exception *nfcxx_eh_exc;
static __thread intptr_t nfcxx_eh_sel;

_Unwind_Reason_Code __nfcxx_personality_v0(int version, _Unwind_Action actions, _Unwind_Exception_Class cls,
                                           struct _Unwind_Exception *exc, struct _Unwind_Context *ctx)
{
  _Unwind_Reason_Code r = __gxx_personality_v0(version, actions, cls, exc, ctx);
  if (r == _URC_INSTALL_CONTEXT) {
    nfcxx_eh_exc = (struct _Unwind_Exception *)_Unwind_GetGR(ctx, __builtin_eh_return_data_regno(0));
    nfcxx_eh_sel = (intptr_t)_Unwind_GetGR(ctx, __builtin_eh_return_data_regno(1));
  }
  return r;
}

void *__nfcxx_eh_ptr(void) { return nfcxx_eh_exc; }
intptr_t __nfcxx_eh_sel(void) { return nfcxx_eh_sel; }
