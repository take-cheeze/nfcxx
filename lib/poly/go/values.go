package main

import (
	"fmt"
	"math"
	"reflect"
	"runtime"
	"strings"
	"unsafe"
	"weak"

	"nfcgo/nfc"
)

// ---- type descriptions ---------------------------------------------------------------------------------------------
// The host describes the C++ parameter and result types of every bound callable with a short string:
//
//	v void   b bool   i signed integer   u unsigned integer   f floating point   s string   a any (a Value)
//	o<class>;  a registered class        [T  std::vector<T>      ?T  std::optional<T>
//
// A signature is "(" parameters ")" result. At the bridge, a class is a *nfc.Obj, a vector a slice, an optional a
// pointer (a nil *nfc.Obj for an optional class), a Value an any.

type descKind byte

const (
	dVoid descKind = iota
	dBool
	dInt
	dUint
	dFloat
	dStr
	dAny
	dClass
	dVec
	dOpt
)

type desc struct {
	k     descKind
	class uint32
	elem  *desc
}

var (
	rtBool   = reflect.TypeOf(false)
	rtInt    = reflect.TypeOf(int(0))
	rtUint   = reflect.TypeOf(uint(0))
	rtFloat  = reflect.TypeOf(float64(0))
	rtString = reflect.TypeOf("")
	rtAny    = reflect.TypeOf((*any)(nil)).Elem()
	rtObjPtr = reflect.TypeOf((*nfc.Obj)(nil))
)

func (d *desc) rtype() reflect.Type {
	switch d.k {
	case dBool:
		return rtBool
	case dInt:
		return rtInt
	case dUint:
		return rtUint
	case dFloat:
		return rtFloat
	case dStr:
		return rtString
	case dAny:
		return rtAny
	case dClass:
		return rtObjPtr
	case dVec:
		return reflect.SliceOf(d.elem.rtype())
	case dOpt:
		if d.elem.k == dClass {
			return rtObjPtr
		}
		return reflect.PointerTo(d.elem.rtype())
	}
	return nil
}

func parseDesc(s string, p *int) *desc {
	if *p >= len(s) {
		return &desc{k: dVoid}
	}
	c := s[*p]
	*p++
	switch c {
	case 'v':
		return &desc{k: dVoid}
	case 'b':
		return &desc{k: dBool}
	case 'i':
		return &desc{k: dInt}
	case 'u':
		return &desc{k: dUint}
	case 'f':
		return &desc{k: dFloat}
	case 's':
		return &desc{k: dStr}
	case 'a':
		return &desc{k: dAny}
	case 'o':
		n := uint32(0)
		for *p < len(s) && s[*p] != ';' {
			n = n*10 + uint32(s[*p]-'0')
			*p++
		}
		*p++
		return &desc{k: dClass, class: n}
	case '[':
		return &desc{k: dVec, elem: parseDesc(s, p)}
	case '?':
		return &desc{k: dOpt, elem: parseDesc(s, p)}
	}
	return &desc{k: dVoid}
}

type callInfo struct {
	params []*desc
	result *desc
}

func parseSig(s string) *callInfo {
	ci := &callInfo{}
	p := 0
	if p < len(s) && s[p] == '(' {
		p++
	}
	for p < len(s) && s[p] != ')' {
		ci.params = append(ci.params, parseDesc(s, &p))
	}
	p++
	ci.result = parseDesc(s, &p)
	return ci
}

// ---- errors raised into the script --------------------------------------------------------------------------------
func raise(class, format string, a ...any) {
	panic(&nfc.Error{Class: class, Msg: fmt.Sprintf(format, a...)})
}

// ---- handles: Go values that stay in the interpreter, named by a number the host holds ------------------------------
func (in *Interp) register(v reflect.Value) uint64 {
	in.mu.Lock()
	defer in.mu.Unlock()
	in.nextHandle++
	in.handles[in.nextHandle] = v
	return in.nextHandle
}

func (in *Interp) handleValue(id uint64) (reflect.Value, bool) {
	in.mu.Lock()
	defer in.mu.Unlock()
	v, ok := in.handles[id]
	return v, ok
}

// ---- objects: C++ objects of registered classes -----------------------------------------------------------------
// A Go value for the host object ID: a *nfc.Obj whose finalizer queues the release of the host's reference. The release
// is applied on the host thread at the next boundary (the finalizer runs on a Go thread of its own).
//
// The finalizer must not refer to the interpreter: the wrapper is reachable from the interpreter's frames, so a finalizer that
// reached the interpreter would make a cycle through the runtime's own tables, and a closed interpreter (1 MB or more) would
// never be collected. It names the interpreter by number and finds it, if it is still open, in the registry.
func (in *Interp) newObj(id uint64, class uint32) *nfc.Obj {
	o := &nfc.Obj{ID: id, Class: class}
	runtime.SetFinalizer(o, releaseObj(in.id))
	in.mu.Lock()
	in.weakObjs[id] = weak.Make(o)
	in.mu.Unlock()
	return o
}

// releaseObj is the finalizer of a wrapper of a host object of the interpreter number IID.
func releaseObj(iid int64) func(*nfc.Obj) {
	return func(o *nfc.Obj) { queueReleaseOf(iid, o.ID) }
}

// queueReleaseOf queues the release of the host object ID for the interpreter number IID; nothing when it was closed.
func queueReleaseOf(iid int64, id uint64) {
	regMu.Lock()
	in := interps[iid]
	regMu.Unlock()
	if in != nil {
		in.queueRelease(id)
	}
}

func (in *Interp) queueRelease(id uint64) {
	in.mu.Lock()
	delete(in.weakObjs, id)
	if !in.closed {
		in.released = append(in.released, id)
	}
	in.mu.Unlock()
}

func (in *Interp) takeReleased() []uint64 {
	in.mu.Lock()
	r := in.released
	in.released = nil
	in.mu.Unlock()
	return r
}

// The wrapper types the backend generates are `struct{ H *nfc.Obj }`; scripts hand them to host functions as values.
func isWrapper(t reflect.Type) bool {
	return t.Kind() == reflect.Pointer && t.Elem().Kind() == reflect.Struct && t.Elem().NumField() >= 1 &&
		t.Elem().Field(0).Name == "H" && t.Elem().Field(0).Type == rtObjPtr
}

func objOf(v reflect.Value) *nfc.Obj {
	if v.Type() == rtObjPtr {
		o, _ := v.Interface().(*nfc.Obj)
		return o
	}
	if isWrapper(v.Type()) && !v.IsNil() {
		o, _ := v.Elem().Field(0).Interface().(*nfc.Obj)
		return o
	}
	return nil
}

// ---- Go -> host -----------------------------------------------------------------------------------------------------
func (in *Interp) putObj(w *writer, o *nfc.Obj) {
	if o == nil {
		w.u8(tNil)
		return
	}
	w.u8(tObj)
	w.u64(o.ID)
	w.u32(o.Class)
}

// yaegi stores a value of an interpreted type that is converted to an interface (a `*Tensor` variable passed as an `any`) as
// interp.valueInterface{node, value}; the reflect.Value inside is the value the script meant. Reading it takes a copy of the
// struct, to get an addressable field, and a look at the unexported field through its address.
func unbox(v reflect.Value) (reflect.Value, bool) {
	t := v.Type()
	if v.Kind() != reflect.Struct || t.Name() != "valueInterface" || !strings.HasSuffix(t.PkgPath(), "yaegi/interp") || t.NumField() != 2 {
		return v, false
	}
	p := reflect.New(t)
	p.Elem().Set(v)
	f := p.Elem().Field(1)
	if f.Type() != reflect.TypeOf(reflect.Value{}) {
		return v, false
	}
	inner := *(*reflect.Value)(unsafe.Pointer(f.UnsafeAddr()))
	if !inner.IsValid() {
		return v, false
	}
	return inner, true
}

// encodeDyn writes a value of any type: plain data by value, host objects as such, everything else as a handle.
func (in *Interp) encodeDyn(w *writer, v reflect.Value) {
	for v.IsValid() {
		if v.Kind() == reflect.Interface {
			if v.IsNil() {
				v = reflect.Value{}
				break
			}
			v = v.Elem()
		} else if u, ok := unbox(v); ok {
			v = u
		} else {
			break
		}
	}
	if !v.IsValid() {
		w.u8(tNil)
		return
	}
	t := v.Type()
	plain := t.PkgPath() == "" // a named type of a compiled package (time.Duration, ...) keeps its methods in a handle
	switch v.Kind() {
	case reflect.Bool:
		if plain {
			if v.Bool() {
				w.u8(tTrue)
			} else {
				w.u8(tFalse)
			}
			return
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if plain {
			w.u8(tInt)
			w.i64(v.Int())
			return
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		if plain && v.Uint() <= math.MaxInt64 {
			w.u8(tInt)
			w.i64(int64(v.Uint()))
			return
		}
	case reflect.Float32, reflect.Float64:
		if plain {
			w.u8(tFloat)
			w.f64(v.Float())
			return
		}
	case reflect.String:
		if plain {
			w.u8(tStr)
			w.str(v.String())
			return
		}
	case reflect.Pointer:
		if v.IsNil() {
			w.u8(tNil)
			return
		}
		if o := objOf(v); o != nil {
			in.putObj(w, o)
			return
		}
		// A pointer to a number, a boolean or a string is the value (the optional of the host's view); nil is nil.
		switch v.Elem().Kind() {
		case reflect.Bool, reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64, reflect.Uint, reflect.Uint8,
			reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Float32, reflect.Float64, reflect.String:
			if v.Elem().Type().PkgPath() == "" {
				in.encodeDyn(w, v.Elem())
				return
			}
		}
	case reflect.Func, reflect.Map, reflect.Chan:
		if v.IsNil() {
			w.u8(tNil)
			return
		}
	}
	w.u8(tHandle)
	w.u64(in.register(v))
}

// encodeAs writes an argument of a bound function whose C++ parameter is described by D.
func (in *Interp) encodeAs(w *writer, v reflect.Value, d *desc) {
	for v.IsValid() && v.Kind() == reflect.Interface {
		if v.IsNil() {
			v = reflect.Value{}
			break
		}
		v = v.Elem()
	}
	switch d.k {
	case dAny:
		in.encodeDyn(w, v)
	case dBool:
		if v.Bool() {
			w.u8(tTrue)
		} else {
			w.u8(tFalse)
		}
	case dInt:
		w.u8(tInt)
		w.i64(v.Int())
	case dUint:
		u := v.Uint()
		if u > math.MaxInt64 {
			raise("TypeError", "integer does not fit the host's integer type")
		}
		w.u8(tInt)
		w.i64(int64(u))
	case dFloat:
		w.u8(tFloat)
		w.f64(v.Float())
	case dStr:
		w.u8(tStr)
		w.str(v.String())
	case dClass:
		if !v.IsValid() {
			w.u8(tNil)
		} else {
			in.putObj(w, objOf(v))
		}
	case dVec:
		if !v.IsValid() {
			w.u8(tArr)
			w.u32(0)
			return
		}
		w.u8(tArr)
		w.u32(uint32(v.Len()))
		for i := 0; i < v.Len(); i++ {
			in.encodeAs(w, v.Index(i), d.elem)
		}
	case dOpt:
		if !v.IsValid() || v.IsNil() {
			w.u8(tNil)
			return
		}
		if d.elem.k == dClass {
			in.putObj(w, objOf(v))
		} else {
			in.encodeAs(w, v.Elem(), d.elem)
		}
	}
}

// ---- host -> Go -----------------------------------------------------------------------------------------------------
func (r *reader) peek() byte {
	if !r.need(1) {
		return tNil
	}
	return r.b[r.p]
}

func (in *Interp) wrapObj(id uint64, class uint32) any {
	o := in.newObj(id, class)
	in.tabMu.RLock()
	fn, ok := in.wraps[class]
	in.tabMu.RUnlock()
	if !ok {
		return o
	}
	return fn.Call([]reflect.Value{reflect.ValueOf(o)})[0].Interface()
}

// decodeDyn reads a value whose type the host does not fix: integers are int, floats float64, arrays []any.
func (in *Interp) decodeDyn(r *reader) any {
	switch tag := r.u8(); tag {
	case tNil:
		return nil
	case tFalse:
		return false
	case tTrue:
		return true
	case tInt:
		return int(r.i64())
	case tFloat:
		return r.f64()
	case tStr:
		return r.str()
	case tArr:
		n := int(r.u32())
		out := make([]any, 0, n)
		for i := 0; i < n && !r.bad; i++ {
			out = append(out, in.decodeDyn(r))
		}
		return out
	case tObj:
		id := r.u64()
		return in.wrapObj(id, r.u32())
	case tHandle:
		v, ok := in.handleValue(r.u64())
		if !ok {
			raise("RuntimeError", "a script value that was released was used")
		}
		if v.CanInterface() {
			return v.Interface()
		}
		return v
	}
	r.bad = true
	return nil
}

// decodeAs reads a result whose bridge type D describes.
func (in *Interp) decodeAs(r *reader, d *desc) reflect.Value {
	switch d.k {
	case dBool:
		return reflect.ValueOf(r.u8() == tTrue)
	case dInt:
		r.u8()
		return reflect.ValueOf(int(r.i64()))
	case dUint:
		r.u8()
		return reflect.ValueOf(uint(r.i64()))
	case dFloat:
		tag := r.u8()
		if tag == tInt {
			return reflect.ValueOf(float64(r.i64()))
		}
		return reflect.ValueOf(r.f64())
	case dStr:
		r.u8()
		return reflect.ValueOf(r.str())
	case dAny:
		v := in.decodeDyn(r)
		return reflect.ValueOf(&v).Elem()
	case dClass:
		if r.peek() == tNil {
			r.u8()
			return reflect.Zero(rtObjPtr)
		}
		r.u8()
		id := r.u64()
		return reflect.ValueOf(in.newObj(id, r.u32()))
	case dVec:
		r.u8()
		n := int(r.u32())
		s := reflect.MakeSlice(d.rtype(), 0, n)
		for i := 0; i < n && !r.bad; i++ {
			s = reflect.Append(s, in.decodeAs(r, d.elem))
		}
		return s
	case dOpt:
		if r.peek() == tNil {
			r.u8()
			return reflect.Zero(d.rtype())
		}
		inner := in.decodeAs(r, d.elem)
		if d.elem.k == dClass {
			return inner
		}
		p := reflect.New(inner.Type())
		p.Elem().Set(inner)
		return p
	}
	return reflect.Value{}
}

// decodeTo reads a value for a parameter of the Go function type T (Value::call on a Go function).
func (in *Interp) decodeTo(r *reader, t reflect.Type) reflect.Value {
	tag := r.peek()
	switch t.Kind() {
	case reflect.Interface:
		v := in.decodeDyn(r)
		out := reflect.New(t).Elem()
		if v != nil {
			out.Set(reflect.ValueOf(v))
		}
		return out
	case reflect.Bool:
		if tag == tTrue || tag == tFalse {
			return reflect.ValueOf(r.u8() == tTrue).Convert(t)
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if tag == tInt {
			r.u8()
			n := r.i64()
			out := reflect.New(t).Elem()
			if out.OverflowInt(n) {
				raise("TypeError", "integer out of range for %s", t)
			}
			out.SetInt(n)
			return out
		}
		if tag == tFloat {
			save := r.p
			r.u8()
			f := r.f64()
			if f == math.Trunc(f) && math.Abs(f) < 9e18 {
				out := reflect.New(t).Elem()
				if !out.OverflowInt(int64(f)) {
					out.SetInt(int64(f))
					return out
				}
			}
			r.p = save
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		if tag == tInt {
			r.u8()
			n := r.i64()
			out := reflect.New(t).Elem()
			if n < 0 || out.OverflowUint(uint64(n)) {
				raise("TypeError", "integer out of range for %s", t)
			}
			out.SetUint(uint64(n))
			return out
		}
	case reflect.Float32, reflect.Float64:
		if tag == tFloat || tag == tInt {
			r.u8()
			var f float64
			if tag == tInt {
				f = float64(r.i64())
			} else {
				f = r.f64()
			}
			out := reflect.New(t).Elem()
			out.SetFloat(f)
			return out
		}
	case reflect.String:
		if tag == tStr {
			r.u8()
			return reflect.ValueOf(r.str()).Convert(t)
		}
	case reflect.Slice:
		if tag == tArr {
			r.u8()
			n := int(r.u32())
			s := reflect.MakeSlice(t, 0, n)
			for i := 0; i < n && !r.bad; i++ {
				s = reflect.Append(s, in.decodeTo(r, t.Elem()))
			}
			return s
		}
	case reflect.Pointer, reflect.Func, reflect.Map, reflect.Struct, reflect.Chan:
		if tag == tNil && t.Kind() != reflect.Struct {
			r.u8()
			return reflect.Zero(t)
		}
		v := in.decodeDyn(r)
		if v != nil {
			rv := reflect.ValueOf(v)
			if rv.Type().AssignableTo(t) {
				return rv
			}
			if rv.Type().ConvertibleTo(t) && rv.Kind() == t.Kind() {
				return rv.Convert(t)
			}
		}
	}
	raise("TypeError", "cannot pass %s as %s", tagName(tag), t)
	return reflect.Value{}
}

func tagName(tag byte) string {
	switch tag {
	case tNil:
		return "nil"
	case tFalse, tTrue:
		return "a boolean"
	case tInt:
		return "an integer"
	case tFloat:
		return "a float"
	case tStr:
		return "a string"
	case tArr:
		return "an array"
	case tObj:
		return "a host object"
	}
	return "a value"
}
