/* a gem-local cast macro: its expansion is a plain cast of its second parameter */
#define NCM_DISCARD(t, v) ((t)(uintptr_t)(v))
