typedef struct { _Atomic(int) counter; _Atomic(unsigned long) size; } state_t;
_Atomic int bare;
static _Atomic(struct node *) head;
