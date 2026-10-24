/* Audited bounded, non-throwing operations used by the call-effects IR test.
 * No heap lifetime or real resource-release contract is claimed by this test. */
void nfcb_init(int *p, int value) { *p = value; }
int nfcb_read(const int *p) { return *p; }
void nfcb_write(int *p, int value) { *p = value; }
int nfcb_consume(int *p) { int value = *p; *p = 0; return value; }
