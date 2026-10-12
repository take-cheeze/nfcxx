// libnfcgo: the Go interpreter (yaegi) of nfcpoly's Go backend, as a C shared library. The C API (nfcgo.h) is a handful
// of functions; lib/poly/nfcpoly_go.cpp is its only client. Built by scripts/setup-poly-go.sh.
//
// A C++ exception must never unwind through Go frames, so no Go function here lets a Go panic out either, and the host
// catches everything its functions throw before it returns to this library (nfcpoly_go.cpp, host_dispatch).
package main

/*
#include <stddef.h>
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"io"
	"log"
	"os"
	"reflect"
	"unsafe"
)

func init() {
	// yaegi reports some internal failures through the standard logger before it panics; the panic is what the host sees.
	log.SetOutput(io.Discard)
}

//export nfcgo_set_host
func nfcgo_set_host(fn unsafe.Pointer) { hostFn = fn }

//export nfcgo_open
func nfcgo_open() (id C.longlong) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintln(os.Stderr, "nfcgo: cannot start the interpreter:", r)
			id = 0
		}
	}()
	in := newInterp()
	regMu.Lock()
	nextID++
	in.id = nextID
	interps[in.id] = in
	regMu.Unlock()
	return C.longlong(in.id)
}

//export nfcgo_close
func nfcgo_close(id C.longlong) {
	regMu.Lock()
	in := interps[int64(id)]
	delete(interps, int64(id))
	regMu.Unlock()
	if in != nil {
		in.mu.Lock()
		in.closed = true
		in.handles = map[uint64]reflect.Value{}
		in.released = nil
		in.mu.Unlock()
	}
}

//export nfcgo_do
func nfcgo_do(id C.longlong, op C.int, msg *C.char, n C.size_t, out **C.char, outn *C.size_t) (status C.int) {
	var reply []byte
	defer func() {
		if r := recover(); r != nil {
			status = stInternal
			w := &writer{}
			w.u32(0)
			w.u32(0)
			w.str(fmt.Sprint("internal error of the bridge: ", r))
			reply = w.b
		}
		p := C.malloc(C.size_t(len(reply) + 1))
		if len(reply) > 0 {
			copy(unsafe.Slice((*byte)(p), len(reply)), reply)
		}
		*out = (*C.char)(p)
		*outn = C.size_t(len(reply))
	}()
	in := lookup(int64(id))
	if in == nil {
		w := &writer{}
		w.u32(0)
		w.u32(0)
		w.str("the interpreter is closed")
		reply = w.b
		return stInternal
	}
	var msgBytes []byte
	if n > 0 {
		msgBytes = unsafe.Slice((*byte)(unsafe.Pointer(msg)), int(n))
	}
	st, rep := in.do(int(op), msgBytes)
	reply = rep
	return C.int(st)
}

func main() {}
