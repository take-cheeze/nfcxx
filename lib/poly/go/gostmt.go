package main

// go statements in scripts: a panic that nothing in a goroutine recovers ends the process, and yaegi starts the goroutines of
// a script with a bare go statement (interp/run.go: `go runCfg(...)`, `go callFn(...)`), with no option or hook to intercept it.
//
// The bridge rewrites the callee of each `go CALL` instead: `go f(a, b)` becomes `go nfcGoGuard__(f)(a, b)`, at the byte offsets
// of the callee (nothing else of the text changes; go/parser finds the statements, as recover.go does for recover()). The go
// statement still evaluates the function value and the arguments in the calling goroutine, in its order, and the value it
// starts is a function of f's own type (nfcGoGuard__ is generic, and nfc.GoGuard builds it with reflect.MakeFunc), so the
// types check as before. That function runs f and recovers a panic of the call: the panic is reported on stderr and the
// goroutine ends normally, as the other goroutines do; the results of the call are zero values, which nothing reads.
//
// What is refused, with a SyntaxError (run.go's compileError), rather than started without the guard: a builtin
// (`go close(c)`, `go panic(x)`, `go println()`, ...), which has no function value to wrap, and a type or a type
// expression written as the callee (a conversion, which Go rejects as a go statement too). The text of a snippet that does
// not parse is returned as it is: yaegi reports the error.

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"reflect"
	"regexp"
	"sort"
)

var goKeyword = regexp.MustCompile(`\bgo\b`)

// builtinNames are the predeclared functions and types: a go statement whose callee is one of them (and not declared in
// the same text) is refused.
var builtinNames = map[string]bool{
	"append": true, "cap": true, "clear": true, "close": true, "complex": true, "copy": true, "delete": true, "imag": true,
	"len": true, "make": true, "max": true, "min": true, "new": true, "panic": true, "print": true, "println": true,
	"real": true, "recover": true,
	"any": true, "bool": true, "byte": true, "comparable": true, "complex64": true, "complex128": true, "error": true,
	"float32": true, "float64": true, "int": true, "int8": true, "int16": true, "int32": true, "int64": true, "rune": true,
	"string": true, "uint": true, "uint8": true, "uint16": true, "uint32": true, "uint64": true, "uintptr": true,
}

// rewriteGo returns the text with each go statement's callee guarded, or a non-empty message when a go statement is refused.
func rewriteGo(text string, decl bool) (string, string) {
	if !goKeyword.MatchString(text) {
		return text, ""
	}
	prefix, suffix := "package p\n", ""
	if !decl {
		prefix, suffix = "package p\nfunc _() {\n", "\n}"
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", prefix+text+suffix, 0)
	if err != nil {
		return text, ""
	}
	type insert struct {
		at  int
		str string
	}
	var ins []insert
	msg := ""
	off := func(p token.Pos) int { return fset.Position(p).Offset - len(prefix) }
	ast.Inspect(f, func(n ast.Node) bool {
		gs, ok := n.(*ast.GoStmt)
		if !ok || msg != "" {
			return msg == ""
		}
		call := gs.Call
		if call == nil || call.Fun == nil {
			return true
		}
		if why := refusedCallee(call.Fun); why != "" {
			msg = fmt.Sprintf("go %s: %s; wrap it in a function literal, go func() { ... }(), which is guarded", exprName(call.Fun), why)
			return false
		}
		ins = append(ins, insert{off(call.Fun.Pos()), "nfcGoGuard__("}, insert{off(call.Fun.End()), ")"})
		return true
	})
	if msg != "" {
		return text, msg
	}
	if len(ins) == 0 {
		return text, ""
	}
	sort.SliceStable(ins, func(i, j int) bool { return ins[i].at < ins[j].at })
	var sb []byte
	last := 0
	for _, in := range ins {
		if in.at < last || in.at > len(text) {
			return text, "a go statement of this text cannot be guarded (its guard would not be placed exactly); rewrite it as a function literal"
		}
		sb = append(sb, text[last:in.at]...)
		sb = append(sb, in.str...)
		last = in.at
	}
	sb = append(sb, text[last:]...)
	return string(sb), ""
}

// refusedCallee tells why a callee cannot be guarded, or "" when it can.
func refusedCallee(fun ast.Expr) string {
	switch x := fun.(type) {
	case *ast.Ident:
		if x.Obj != nil {
			if x.Obj.Kind == ast.Typ {
				return "it is a type, not a function"
			}
			return ""
		}
		if builtinNames[x.Name] {
			return "it is the builtin " + x.Name + ", which has no function value to guard"
		}
	case *ast.ArrayType, *ast.MapType, *ast.ChanType, *ast.StructType, *ast.InterfaceType:
		return "it is a type, not a function"
	}
	return ""
}

func exprName(fun ast.Expr) string {
	switch x := fun.(type) {
	case *ast.Ident:
		return x.Name
	case *ast.SelectorExpr:
		return exprName(x.X) + "." + x.Sel.Name
	}
	return "call"
}

// goGuard is nfc.GoGuard: the function of f's type that calls f and recovers a panic of the call. The panic is reported on
// stderr (the interpreter's own stderr discards its frames), and the call returns zero results. A nil function is not
// refused here: the call panics inside the goroutine, which the guard reports (Go stops the process with a fatal error).
func goGuard(f any) any {
	fv := reflect.ValueOf(f)
	if fv.Kind() != reflect.Func {
		panic(fmt.Sprintf("go of a value that is not a function (%T)", f))
	}
	t := fv.Type()
	return reflect.MakeFunc(t, func(args []reflect.Value) []reflect.Value {
		return guardedCall(fv, args)
	}).Interface()
}

func guardedCall(fv reflect.Value, args []reflect.Value) (out []reflect.Value) {
	t := fv.Type()
	defer func() {
		if r := recover(); r != nil {
			_, msg := describePanic(r)
			fmt.Fprintf(os.Stderr, "panic in a goroutine of the script, contained by its go statement: %s\n", msg)
			out = make([]reflect.Value, t.NumOut())
			for i := range out {
				out[i] = reflect.Zero(t.Out(i))
			}
		}
	}()
	if t.IsVariadic() {
		return fv.CallSlice(args) // reflect passes the variadic arguments as one slice to the wrapper
	}
	return fv.Call(args)
}
