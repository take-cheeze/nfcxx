/*
nfcxx_vla_asan.c -- the runtime of C++ variable-length arrays under -fsanitize=address (docs/notes/asan.md, "C++
variable-length arrays"). EDG lowers a VLA to these four calls; EDG's own implementation is 3rd/edg/lib_src/vla_alloc.c,
in libC.a.

The driver links this object ahead of libC.a (scripts/asan-vla), so the symbols here are the ones EDG's generated code
calls, and vla_alloc.o of libC.a is not pulled in. EDG's allocator serves a VLA under 4096 bytes from one shared 32700-byte
block: no redzone separates two such VLAs, so an overflow of one writes into the next, unreported, and the pool is not
thread-safe. This one gives every VLA a malloc block of exactly the requested size. libasan intercepts malloc, so each VLA
gets redzones, and the block is freed when the VLA's scope ends: a pointer kept past the scope is a heap-use-after-free.

The bookkeeping is EDG's: a stack of records (block, frame marker) per thread. __vla_dealloc pops to the record of its
slot, freeing the records above it (those belong to scopes a jump left). A longjmp (EDG's exception runtime) can leave
records of frames that are no longer on the stack; __vla_alloc finds them by their frame markers and frees them.

Built by scripts/asan-vla with -fsanitize=address. The functions that take the address of a local (the frame markers
point into the stack) are built with no_sanitize_address, so that the markers are real stack addresses even when
libasan's use-after-return detection is on.
*/

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct vla_record {
  void *storage;        /* the block a VLA's slot points to */
  uintptr_t frame_marker;   /* an address in the frame of the __vla_alloc call that made the record (an integer: the
                               record outlives the frame, and only its order matters) */
} vla_record;

static __thread vla_record *records;
static __thread ptrdiff_t last = -1;   /* the newest record, -1 when there is none */
static __thread ptrdiff_t capacity;

static void fail(const char *msg) __attribute__((noreturn));
static void fail(const char *msg) {
  fprintf(stderr, "nfcxx: %s\n", msg);
  abort();
}

/* The direction the stack grows in, measured against a local of the caller (caller_local is an address in __vla_alloc's
   real frame). Not measured against the VLA's slot: under -fsanitize=address with detect_stack_use_after_return (the
   default of gcc 13's libasan) the slot of a function built with it can lie in libasan's fake stack, outside the real
   stack, where it says nothing about the direction. */
__attribute__((noinline, no_sanitize_address))
static int stack_grows_up(uintptr_t caller_local) {
  char here;
  return (uintptr_t)&here > caller_local;
}

/* A record is dead when its marker lies deeper in the stack than the __vla_alloc frame at here, the one of the current
   call: the frame that made the record was left by a longjmp. The stack grows towards higher addresses when grows_up. */
static int marker_is_dead(uintptr_t marker, uintptr_t here, int grows_up) {
  return grows_up ? marker > here : marker < here;
}

/* Free the records made by dead frames, newest first; stop at the first live one. */
static void free_dead(uintptr_t here, int grows_up) {
  ptrdiff_t i = last;
  while (i >= 0 && marker_is_dead(records[i].frame_marker, here, grows_up)) {
    free(records[i].storage);
    --i;
  }
  last = i;
}

/* ptr points to a pointer variable: allocate n_bytes and store the block's address in it. */
__attribute__((no_sanitize_address))
void __vla_alloc(void *ptr, ptrdiff_t n_bytes) {
  char here;   /* its address is the frame marker of the new record */
  int grows_up;
  void *storage;

  if (n_bytes == 0) {
    n_bytes = 1;   /* a zero-length VLA still has a block of its own */
  } else if (n_bytes < 0) {
    fail("negative VLA size");
  }
  grows_up = stack_grows_up((uintptr_t)&here);
  if (last >= 0) {
    free_dead((uintptr_t)&here, grows_up);
  }
  if (last + 1 == capacity) {
    ptrdiff_t n = capacity ? 2 * capacity : 64;
    vla_record *grown = realloc(records, (size_t)n * sizeof *grown);
    if (grown == NULL) {
      fail("VLA allocation failed");
    }
    records = grown;
    capacity = n;
  }
  storage = malloc((size_t)n_bytes);   /* exactly n_bytes: the redzone starts right after the VLA */
  if (storage == NULL) {
    fail("VLA allocation failed");
  }
  ++last;
  records[last].storage = storage;
  records[last].frame_marker = (uintptr_t)&here;
  *(void **)ptr = storage;
}

/* ptr points to the pointer variable of a VLA: free its block, and the blocks of the scopes it left. */
void __vla_dealloc(void *ptr) {
  void *slot = *(void **)ptr;
  ptrdiff_t i = last;
  for (; i >= 0; --i) {
    void *storage = records[i].storage;
    int match = storage == slot;
    free(storage);
    if (match) {
      break;
    }
  }
  if (i < 0) {
    fail("__vla_dealloc: no VLA is allocated at this slot");
  }
  last = i - 1;
}

/* Like __vla_dealloc, but given the array's address rather than the address of the pointer variable. */
void __vla_dealloc_eh(void *ptr) {
  __vla_dealloc(&ptr);
}

/* The number of live VLA blocks of this thread (EDG's DEBUG runtime has the same function). */
long __vla_number_of_active_allocations(void) {
  return (long)last + 1;
}
