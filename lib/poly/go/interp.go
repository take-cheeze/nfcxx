package main

/*
#include <stdlib.h>
#include <stddef.h>
typedef int (*nfcgo_host_fn)(long long interp, int op, const char* in, size_t n, char** out, size_t* outn);
static int nfcgo_call_host(void* fn, long long interp, int op, const char* in, size_t n, char** out, size_t* outn) {
	return ((nfcgo_host_fn)fn)(interp, op, in, n, out, outn);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math"
	"reflect"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"
	"weak"

	"github.com/traefik/yaegi/interp"

	"nfcgo/nfc"
)

// An operation the host asks of this library (nfcgo_do), and the statuses that come back.
const (
	opEval    = 1 // run a source text
	opDecl    = 2 // define generated declarations
	opCall    = 3 // call a Go value (Value::call)
	opArray   = 4 // the elements of a slice handle
	opInspect = 5 // the text of a value
	opType    = 6 // the type name of a value
	opIsArray = 7 // whether a handle is a slice or an array
)

const (
	stOK       = 0
	stScript   = 1 // a panic nothing recovered: class, message, backtrace
	stSyntax   = 2 // the source did not compile: message
	stHost     = 3 // a panic that carries a C++ exception: the exception's id, message
	stInternal = 4 // a failure of the bridge itself: message
)

// What the host answers to a call from Go (nfcgo_host_fn), in the status it returns.
const (
	hostOK        = 0
	hostException = 1 // a C++ exception: id, message
	hostType      = 2 // a conversion failure: message
	hostRepanic   = 3 // a script error that came back from a nested call: raise the same one
	hostPlain     = 4 // class, message
	hostThread    = 5 // called from a thread the host did not enter on
)

const hostOpCall = 1

var (
	gcMu    sync.Mutex // one nfc.GC() at a time: it changes process-wide collector settings
	regMu   sync.Mutex
	interps = map[int64]*Interp{}
	nextID  int64
	hostFn  unsafe.Pointer
)

type liveVar struct {
	name string
	kind byte // i u f b s
	cell reflect.Value
	last any
}

type Interp struct {
	id  int64
	itp *interp.Interpreter

	mu           sync.Mutex // handles, nextHandle, released, closed
	handles      map[uint64]reflect.Value
	nextHandle   uint64
	released     []uint64
	closed       bool
	weakObjs     map[uint64]weak.Pointer[nfc.Obj] // the wrappers of host objects, to find the dead ones at gcNow
	noFinalizers atomic.Bool                      // the finalizers release nothing (a test knob: nfc.FinalizersOff)

	tabMu sync.RWMutex // calls, wraps
	calls map[uint32]*callInfo
	wraps map[uint32]reflect.Value

	live            []*liveVar
	lastPanic       any
	recoverShadowed bool // the script declared its own recover: the builtin is no longer wrapped (recover.go)
	ret             []any
	imported        map[string]bool
	ownerTid        atomic.Int64
}

func lookup(id int64) *Interp {
	regMu.Lock()
	defer regMu.Unlock()
	return interps[id]
}

// ---- the interpreter ----------------------------------------------------------------------------------------------
type emptyFS struct{}

func (emptyFS) Open(string) (fs.File, error) { return nil, fs.ErrNotExist }

func newInterp() *Interp {
	in := &Interp{
		handles:  map[uint64]reflect.Value{},
		weakObjs: map[uint64]weak.Pointer[nfc.Obj]{},
		calls:    map[uint32]*callInfo{},
		wraps:    map[uint32]reflect.Value{},
		imported: map[string]bool{},
	}
	in.itp = interp.New(interp.Options{
		Stdin:                strings.NewReader(""),
		Stderr:               io.Discard, // yaegi reports every frame a panic passes through there
		SourcecodeFilesystem: emptyFS{},  // `import "x/y"` finds no source on disk
	})
	exports, imports := whitelist()
	exports["nfc/nfc"] = in.nfcExports()
	if err := in.itp.Use(exports); err != nil {
		panic(err)
	}
	var sb strings.Builder
	sb.WriteString("import (\n")
	for _, p := range imports {
		sb.WriteString("\t" + fmt.Sprintf("%q", p) + "\n")
		in.imported[p] = true
	}
	for _, p := range sourcePackages {
		sb.WriteString("\t" + fmt.Sprintf("%q", p) + "\n")
		in.imported[p] = true
	}
	sb.WriteString("\t\"nfc\"\n)")
	if _, err := in.eval(sb.String()); err != nil {
		panic(err)
	}
	// the callee of each go statement of a script is wrapped in it (gostmt.go); generic, so it has the callee's type
	if _, err := in.eval("func nfcGoGuard__[F any](f F) F { return nfc.GoGuard(f).(F) }"); err != nil {
		panic(err)
	}
	return in
}

func (in *Interp) nfcExports() map[string]reflect.Value {
	return map[string]reflect.Value{
		"Obj":           reflect.ValueOf((*nfc.Obj)(nil)),
		"Error":         reflect.ValueOf((*nfc.Error)(nil)),
		"HostError":     reflect.ValueOf((*nfc.HostError)(nil)),
		"Call":          reflect.ValueOf(in.call),
		"Ref":           reflect.ValueOf(in.ref),
		"Handle":        reflect.ValueOf(in.handleAny),
		"Ret":           reflect.ValueOf(in.setRet),
		"GC":            reflect.ValueOf(in.gcNow),
		"FinalizersOff": reflect.ValueOf(in.finalizersOff),
		"Go":            reflect.ValueOf(goSafe),
		"GoGuard":       reflect.ValueOf(goGuard),
		"Unwrap":        reflect.ValueOf(unwrap),
		"ErrClass":      reflect.ValueOf(errClass),
		"ErrMessage":    reflect.ValueOf(errMessage),
	}
}

func (in *Interp) ref(id uint64, class uint32) *nfc.Obj { return in.newObj(id, class) }

// handleAny is the Go value behind a handle the host holds (a variable declared from a Value).
func (in *Interp) handleAny(id uint64) any {
	v, ok := in.handleValue(id)
	if !ok {
		raise("RuntimeError", "a script value that was released was used")
	}
	if v.CanInterface() {
		return v.Interface()
	}
	return v
}

func (in *Interp) setRet(v ...any) { in.ret = v }

// gcNow runs the Go garbage collector and queues the release of every host object whose wrapper it found dead, so that the
// host applies them at the next boundary. The finalizers (newObj) release the same objects, but they run on a goroutine of
// their own at a time of the runtime's choosing; weak pointers are cleared by the time runtime.GC returns, which makes this
// exact: what the script no longer references is released before the evaluation that called gc returns.
//
// "By the time runtime.GC returns" holds only while no other collection starts: runtime.GC finishes the sweep of its own cycle
// unless a second cycle (triggered by allocation, by the heap goal or by GOMEMLIMIT) has started meanwhile, and a weak pointer is
// cleared when its span is swept. So the collector is held off while this runs (the heap goal and the memory limit are lifted
// for the duration; gcMu keeps two interpreters from restoring each other's settings), and a second pass runs because
// sync.Pool buffers survive one cycle (their victim cache) and may hold the last reference to a value. More passes run while a
// pass still finds something new, up to four.
func (in *Interp) gcNow() {
	gcMu.Lock()
	defer gcMu.Unlock()
	oldPercent := debug.SetGCPercent(-1)
	oldLimit := debug.SetMemoryLimit(math.MaxInt64)
	defer func() {
		debug.SetMemoryLimit(oldLimit)
		debug.SetGCPercent(oldPercent)
	}()
	for pass := 1; pass <= 4; pass++ {
		debug.FreeOSMemory() // a full collection with the sweep finished, and the memory the interpreter's garbage took goes back
		if in.sweepDead() == 0 && pass >= 2 {
			break
		}
	}
}

// sweepDead queues the release of the objects whose weak pointers were cleared and returns how many there were.
func (in *Interp) sweepDead() int {
	n := 0
	in.mu.Lock()
	for id, w := range in.weakObjs {
		if w.Value() == nil {
			delete(in.weakObjs, id)
			n++
			if !in.closed {
				in.released = append(in.released, id)
			}
		}
	}
	in.mu.Unlock()
	return n
}

// finalizersOff silences the finalizers of the wrappers (for tests): the objects are then released only by nfc.GC(), so a
// check of the weak-pointer sweep does not depend on when the finalizer goroutine runs.
func (in *Interp) finalizersOff(off bool) { in.noFinalizers.Store(off) }

// ---- the host ---------------------------------------------------------------------------------------------------------
func (in *Interp) hostCall(op int, payload []byte) (int, []byte) {
	var p *C.char
	var n C.size_t
	var inp *C.char
	if len(payload) > 0 {
		inp = (*C.char)(unsafe.Pointer(&payload[0]))
	}
	st := C.nfcgo_call_host(hostFn, C.longlong(in.id), C.int(op), inp, C.size_t(len(payload)), &p, &n)
	var out []byte
	if p != nil {
		out = C.GoBytes(unsafe.Pointer(p), C.int(n))
		C.free(unsafe.Pointer(p))
	}
	return int(st), out
}

// The live variables: bound C++ variables are Go variables of the script, copied from the host before the script runs
// and after each host call, and copied back (when they changed) when a host function is called and when the script
// ends. So a host function sees the script's writes, and the script sees the host function's.
func (lv *liveVar) read() any {
	switch lv.kind {
	case 'i':
		return lv.cell.Int()
	case 'u':
		return int64(lv.cell.Uint())
	case 'f':
		return lv.cell.Float()
	case 'b':
		return lv.cell.Bool()
	}
	return lv.cell.String()
}

func (lv *liveVar) write(v any) {
	switch lv.kind {
	case 'i':
		if x, ok := v.(int64); ok {
			lv.cell.SetInt(x)
		}
	case 'u':
		if x, ok := v.(int64); ok {
			lv.cell.SetUint(uint64(x))
		}
	case 'f':
		if x, ok := v.(float64); ok {
			lv.cell.SetFloat(x)
		}
	case 'b':
		if x, ok := v.(bool); ok {
			lv.cell.SetBool(x)
		}
	case 's':
		if x, ok := v.(string); ok {
			lv.cell.SetString(x)
		}
	}
	lv.last = v
}

func putLive(w *writer, v any) {
	switch x := v.(type) {
	case int64:
		w.u8(tInt)
		w.i64(x)
	case float64:
		w.u8(tFloat)
		w.f64(x)
	case bool:
		if x {
			w.u8(tTrue)
		} else {
			w.u8(tFalse)
		}
	case string:
		w.u8(tStr)
		w.str(x)
	}
}

func getLive(r *reader, kind byte) any {
	tag := r.u8()
	switch tag {
	case tInt:
		if kind == 'f' {
			return float64(r.i64())
		}
		return r.i64()
	case tFloat:
		return r.f64()
	case tTrue:
		return true
	case tFalse:
		return false
	case tStr:
		return r.str()
	}
	return nil
}

// writeMeta puts what the host must learn at a boundary in front of a message: the live variables the script changed,
// and the objects whose wrappers were collected.
//
// It returns undo, for a message the host refuses without reading (hostThread): the releases go back on the queue and the
// variables are unmarked again, so that the next message that the host does read carries them.
func (in *Interp) writeMeta(w *writer) (undo func()) {
	type change struct {
		idx  int
		v    any
		prev any
	}
	var ch []change
	for i, lv := range in.live {
		if !lv.cell.IsValid() {
			continue
		}
		if cur := lv.read(); cur != lv.last {
			ch = append(ch, change{i, cur, lv.last})
			lv.last = cur
		}
	}
	w.u32(uint32(len(ch)))
	for _, c := range ch {
		w.u32(uint32(c.idx))
		putLive(w, c.v)
	}
	rel := in.takeReleased()
	w.u32(uint32(len(rel)))
	for _, id := range rel {
		w.u64(id)
	}
	return func() {
		for _, c := range ch {
			in.live[c.idx].last = c.prev
		}
		in.mu.Lock()
		if !in.closed {
			in.released = append(rel, in.released...)
		}
		in.mu.Unlock()
	}
}

// readMeta reads what the host puts in front of its messages: the handles it dropped, the live variables' values.
func (in *Interp) readMeta(r *reader) {
	n := int(r.u32())
	if n > 0 {
		in.mu.Lock()
		for i := 0; i < n && !r.bad; i++ {
			delete(in.handles, r.u64())
		}
		in.mu.Unlock()
	}
	in.readLive(r)
}

func (in *Interp) readLive(r *reader) {
	n := int(r.u32())
	for i := 0; i < n && !r.bad; i++ {
		if i < len(in.live) {
			lv := in.live[i]
			v := getLive(r, lv.kind)
			if lv.cell.IsValid() {
				lv.write(v)
			}
		} else {
			getLive(r, 'i')
		}
	}
}

// call is nfc.Call: the generated wrapper of a bound function or method calls the host through it.
func (in *Interp) call(id int, args ...any) any {
	if tid := currentThread(); tid != 0 && tid != in.ownerTid.Load() {
		raise("GoroutineError", "a host function can only be called from the goroutine that entered the script, not from a goroutine the script started")
	}
	in.tabMu.RLock()
	ci := in.calls[uint32(id)]
	in.tabMu.RUnlock()
	if ci == nil {
		raise("RuntimeError", "call of an unknown host function %d", id)
	}
	if len(args) != len(ci.params) {
		raise("ArgumentError", "wrong number of arguments (given %d, expected %d)", len(args), len(ci.params))
	}
	// The arguments first: encoding can panic, and the meta part drains the release queue and marks the variables as copied.
	var body writer
	body.u32(uint32(id))
	for i, a := range args {
		in.encodeAs(&body, reflect.ValueOf(a), ci.params[i])
	}
	w := &writer{}
	undo := in.writeMeta(w)
	w.raw(body.b)
	st, out := in.hostCall(hostOpCall, w.b)
	if st == hostThread {
		undo() // the host refused the message without reading it: what it carried is still to be told
	}
	r := &reader{b: out}
	in.readLive(r)
	switch st {
	case hostOK:
		if ci.result.k == dVoid {
			return nil
		}
		v := in.decodeAs(r, ci.result)
		if r.bad {
			raise("RuntimeError", "malformed result from the host")
		}
		return v.Interface()
	case hostException:
		id := r.u64()
		he := &nfc.HostError{Msg: r.str(), ID: id}
		iid := in.id
		runtime.SetFinalizer(he, func(he *nfc.HostError) { queueReleaseOf(iid, he.ID|excBit) })
		panic(he)
	case hostType:
		raise("TypeError", "%s", r.str())
	case hostRepanic:
		panic(in.lastPanic)
	case hostPlain:
		cls := r.str()
		raise(cls, "%s", r.str())
	case hostThread:
		raise("GoroutineError", "a host function can only be called from the goroutine that entered the script, not from a goroutine the script started")
	}
	raise("RuntimeError", "unknown status %d from the host", st)
	return nil
}

const excBit = uint64(1) << 63

// ---- operations ---------------------------------------------------------------------------------------------------------
func (in *Interp) enter() func() {
	tid := currentThread()
	prev := in.ownerTid.Swap(tid)
	return func() { in.ownerTid.Store(prev) }
}

// do is the body of nfcgo_do. It returns a status and the reply: the meta part for the host, then the payload.
func (in *Interp) do(op int, msg []byte) (status int, reply []byte) {
	defer func() {
		if r := recover(); r != nil {
			status = stInternal
			w := &writer{}
			w.u32(0)
			w.u32(0)
			w.str(fmt.Sprint("internal error of the bridge: ", r))
			reply = w.b
		}
	}()
	defer in.enter()()
	r := &reader{b: msg}
	var body writer
	switch op {
	case opEval, opCall, opDecl:
		in.readMeta(r)
	}
	switch op {
	case opEval:
		status = in.opEval(r, &body)
	case opDecl:
		status = in.opDecl(r, &body)
	case opCall:
		status = in.opCall(r, &body)
	case opArray:
		status = in.opArray(r, &body)
	case opInspect:
		status = in.opInspect(r, &body)
	case opType:
		status = in.opType(r, &body)
	case opIsArray:
		status = in.opIsArray(r, &body)
	default:
		status = stInternal
		body.str("unknown operation")
	}
	var w writer
	in.writeMeta(&w)
	w.raw(body.b)
	return status, w.b
}

func (in *Interp) failure(body *writer, err error) int {
	var ce *compileError
	var pe *panicError
	switch {
	case errors.As(err, &ce):
		body.str(ce.msg)
		return stSyntax
	case errors.As(err, &pe):
		return in.panicStatus(body, pe)
	}
	body.str(err.Error())
	return stInternal
}

func (in *Interp) panicStatus(body *writer, pe *panicError) int {
	in.lastPanic = pe.value
	if he, ok := pe.value.(*nfc.HostError); ok && he.ID != 0 {
		body.u64(he.ID)
		body.str(he.Msg)
		return stHost
	}
	cls, msg := describePanic(pe.value)
	body.str(cls)
	body.str(msg)
	lines := backtrace(pe.stack)
	body.u32(uint32(len(lines)))
	for _, l := range lines {
		body.str(l)
	}
	return stScript
}

func (in *Interp) opEval(r *reader, body *writer) int {
	src := r.str()
	v, err := in.evalSource(src)
	if err != nil {
		return in.failure(body, err)
	}
	in.encodeDyn(body, v)
	return stOK
}

func (in *Interp) opCall(r *reader, body *writer) (status int) {
	target := in.decodeRaw(r)
	method := r.str()
	nargs := int(r.u32())
	fn := target
	if method != "" {
		if target.IsValid() {
			fn = target.MethodByName(method)
		} else {
			fn = reflect.Value{}
		}
		if !fn.IsValid() {
			return in.scriptFail(body, "NoMethodError", fmt.Sprintf("undefined method '%s' for %s", method, typeName(target)))
		}
	}
	if !fn.IsValid() || fn.Kind() != reflect.Func {
		return in.scriptFail(body, "TypeError", fmt.Sprintf("%s is not callable", typeName(fn)))
	}
	ft := fn.Type()
	if !ft.IsVariadic() && ft.NumIn() != nargs || ft.IsVariadic() && nargs < ft.NumIn()-1 {
		return in.scriptFail(body, "ArgumentError", fmt.Sprintf("wrong number of arguments (given %d, expected %d)", nargs, ft.NumIn()))
	}
	args := make([]reflect.Value, nargs)
	var decodeErr any
	func() {
		defer func() { decodeErr = recover() }()
		for i := 0; i < nargs; i++ {
			t := ft.In(minInt(i, ft.NumIn()-1))
			if ft.IsVariadic() && i >= ft.NumIn()-1 {
				t = ft.In(ft.NumIn() - 1).Elem()
			}
			args[i] = in.decodeTo(r, t)
		}
	}()
	if decodeErr != nil {
		return in.failure(body, &panicError{value: unwrap(decodeErr)})
	}
	var outs []reflect.Value
	func() {
		defer func() {
			if rec := recover(); rec != nil {
				outs = nil
				status = in.failure(body, &panicError{value: unwrap(rec), stack: string(debug.Stack())})
			}
		}()
		outs = fn.Call(args)
		status = stOK
	}()
	if status != stOK {
		return status
	}
	if n := len(outs); n > 0 {
		if last := outs[n-1]; last.Type() == reflect.TypeOf((*error)(nil)).Elem() && !last.IsNil() {
			return in.failure(body, &panicError{value: last.Interface()})
		}
		in.encodeDyn(body, outs[0])
	} else {
		body.u8(tNil)
	}
	return stOK
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func (in *Interp) scriptFail(body *writer, cls, msg string) int {
	return in.panicStatus(body, &panicError{value: &nfc.Error{Class: cls, Msg: msg}})
}

// decodeRaw reads a value for use as the receiver of a call: a handle is the Go value itself, plain data its reflect value.
func (in *Interp) decodeRaw(r *reader) reflect.Value {
	if r.peek() == tHandle {
		r.u8()
		v, ok := in.handleValue(r.u64())
		if !ok {
			raise("RuntimeError", "a script value that was released was used")
		}
		return v
	}
	return reflect.ValueOf(in.decodeDyn(r))
}

func typeName(v reflect.Value) string {
	if !v.IsValid() {
		return "nil"
	}
	return v.Type().String()
}

func (in *Interp) opArray(r *reader, body *writer) int {
	v := in.decodeRaw(r)
	if v.Kind() != reflect.Slice && v.Kind() != reflect.Array {
		return in.scriptFail(body, "TypeError", fmt.Sprintf("%s is not an array", typeName(v)))
	}
	body.u32(uint32(v.Len()))
	for i := 0; i < v.Len(); i++ {
		in.encodeDyn(body, v.Index(i))
	}
	return stOK
}

func (in *Interp) opInspect(r *reader, body *writer) int {
	v := in.decodeRaw(r)
	if v.IsValid() && v.CanInterface() {
		body.str(fmt.Sprintf("%v", v.Interface()))
	} else {
		body.str(typeName(v))
	}
	return stOK
}

func (in *Interp) opType(r *reader, body *writer) int {
	v := in.decodeRaw(r)
	body.str(typeName(v))
	return stOK
}

func (in *Interp) opIsArray(r *reader, body *writer) int {
	v := in.decodeRaw(r)
	if v.IsValid() && (v.Kind() == reflect.Slice || v.Kind() == reflect.Array) {
		body.u8(1)
	} else {
		body.u8(0)
	}
	return stOK
}

// opDecl defines the declarations the host generated: callable signatures, live variables, class wrappers, source.
func (in *Interp) opDecl(r *reader, body *writer) int {
	n := int(r.u32())
	in.tabMu.Lock()
	for i := 0; i < n && !r.bad; i++ {
		id := r.u32()
		in.calls[id] = parseSig(r.str())
	}
	in.tabMu.Unlock()
	nl := int(r.u32())
	var fresh []*liveVar
	for i := 0; i < nl && !r.bad; i++ {
		lv := &liveVar{name: r.str(), kind: r.u8()}
		in.live = append(in.live, lv)
		fresh = append(fresh, lv)
	}
	nw := int(r.u32())
	type wrapReq struct {
		class uint32
		name  string
	}
	var wraps []wrapReq
	for i := 0; i < nw && !r.bad; i++ {
		c := r.u32()
		wraps = append(wraps, wrapReq{c, r.str()})
	}
	src := r.str()
	if r.bad {
		body.str("malformed declaration message")
		return stInternal
	}
	if _, err := in.run(group{text: src, decl: true}); err != nil {
		return in.failure(body, err)
	}
	if len(fresh) > 0 {
		globals := in.itp.Globals()
		for _, lv := range fresh {
			g, ok := globals[lv.name]
			if !ok || !g.CanSet() {
				body.str("the live variable " + lv.name + " could not be defined")
				return stInternal
			}
			lv.cell = g
			lv.last = lv.read()
		}
	}
	for _, wr := range wraps {
		fn, err := in.eval(wr.name)
		if err != nil {
			return in.failure(body, err)
		}
		in.tabMu.Lock()
		in.wraps[wr.class] = fn
		in.tabMu.Unlock()
	}
	return stOK
}

// ---- panics as the host sees them -------------------------------------------------------------------------------------
func describePanic(v any) (cls, msg string) {
	v = unwrap(v)
	switch e := v.(type) {
	case *nfc.Error:
		return e.Class, e.Msg
	case *nfc.HostError:
		return "HostError", e.Msg
	case runtime.Error:
		return "runtime.Error", e.Error()
	case error:
		t := strings.TrimPrefix(reflect.TypeOf(e).String(), "*")
		if strings.HasPrefix(t, "struct") {
			t = "error"
		}
		return t, e.Error()
	case string:
		return "panic", e
	}
	return "panic", fmt.Sprint(v)
}

// A panic(x) in script code reaches recover() as a reflect.Value holding x (a yaegi quirk), which defeats r.(string) and
// r.(error); unwrap gives back x.
func unwrap(v any) any {
	if rv, ok := v.(reflect.Value); ok {
		if rv.IsValid() && rv.CanInterface() {
			return rv.Interface()
		}
		return nil
	}
	return v
}

// goSafe is nfc.Go: it runs f in a goroutine and hands back a channel that receives nil when f returned, or the *nfc.Error
// (the class and message the host would see) of the panic that f did not recover. A script's own `go f()` is guarded
// differently: its callee is wrapped by the bridge (gostmt.go) and the process goes on, but a `go` statement that is refused
// (a builtin callee) and a goroutine that yaegi starts itself (time.AfterFunc, which runs f in a goroutine of the Go runtime)
// are not guarded. nfc.Go stays the way to start one that reports its panic to the caller.
func goSafe(f func()) <-chan error {
	ch := make(chan error, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				cls, msg := describePanic(r)
				ch <- &nfc.Error{Class: cls, Msg: msg}
			}
		}()
		f()
		ch <- nil
	}()
	return ch
}

func errClass(v any) string   { c, _ := describePanic(v); return c }
func errMessage(v any) string { _, m := describePanic(v); return m }

func backtrace(stack string) []string {
	var out []string
	for _, l := range strings.Split(stack, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "goroutine ") {
			continue
		}
		out = append(out, l)
		if len(out) >= 24 {
			break
		}
	}
	if len(out) == 0 {
		out = append(out, "(no backtrace)")
	}
	return out
}
