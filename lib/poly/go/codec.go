package main

// The wire format between the host (lib/poly/nfcpoly_go.cpp) and this library: a byte string in each direction, built
// from these tags. Everything is little endian.
//
//	tNil
//	tFalse, tTrue
//	tInt     i64
//	tFloat   f64
//	tStr     u32 length, bytes
//	tArr     u32 count, values
//	tObj     u64 id (key in the host's object table), u32 class
//	tHandle  u64 id (key in handles: a Go value that stays in the interpreter)

import (
	"encoding/binary"
	"math"
)

const (
	tNil byte = iota
	tFalse
	tTrue
	tInt
	tFloat
	tStr
	tArr
	tObj
	tHandle
)

type writer struct{ b []byte }

func (w *writer) u8(v byte)     { w.b = append(w.b, v) }
func (w *writer) u32(v uint32)  { w.b = binary.LittleEndian.AppendUint32(w.b, v) }
func (w *writer) u64(v uint64)  { w.b = binary.LittleEndian.AppendUint64(w.b, v) }
func (w *writer) i64(v int64)   { w.u64(uint64(v)) }
func (w *writer) f64(v float64) { w.u64(math.Float64bits(v)) }
func (w *writer) str(s string) {
	w.u32(uint32(len(s)))
	w.b = append(w.b, s...)
}
func (w *writer) raw(b []byte) { w.b = append(w.b, b...) }

// A reader over a message that the host built. A short or malformed message sets bad and reads zeros, so that a bug on
// the other side surfaces as an error status rather than a crash.
type reader struct {
	b   []byte
	p   int
	bad bool
}

func (r *reader) need(n int) bool {
	if r.bad || n < 0 || r.p+n > len(r.b) {
		r.bad = true
		return false
	}
	return true
}
func (r *reader) u8() byte {
	if !r.need(1) {
		return 0
	}
	v := r.b[r.p]
	r.p++
	return v
}
func (r *reader) u32() uint32 {
	if !r.need(4) {
		return 0
	}
	v := binary.LittleEndian.Uint32(r.b[r.p:])
	r.p += 4
	return v
}
func (r *reader) u64() uint64 {
	if !r.need(8) {
		return 0
	}
	v := binary.LittleEndian.Uint64(r.b[r.p:])
	r.p += 8
	return v
}
func (r *reader) i64() int64   { return int64(r.u64()) }
func (r *reader) f64() float64 { return math.Float64frombits(r.u64()) }
func (r *reader) str() string {
	n := int(r.u32())
	if !r.need(n) {
		return ""
	}
	s := string(r.b[r.p : r.p+n])
	r.p += n
	return s
}
func (r *reader) rest() []byte { return r.b[r.p:] }
