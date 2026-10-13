package main

// Running a source text in yaegi's REPL mode. Yaegi accepts either declarations (when the text starts with func, type,
// var, const or import) or statements, never a mix, and does not say what the value of the last statement is: an
// expression statement whose value is not used leaves a stale reflect.Value behind. So a source is cut into its top level
// statements, declarations and statements are evaluated in separate groups, and the last statement, when it is an
// expression, is evaluated as nfc.Ret(<expression>) so that its value is known exactly.

import (
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/scanner"
	"go/token"
	"reflect"
	"strconv"
	"strings"
	"unsafe"

	"github.com/traefik/yaegi/interp"
)

type chunk struct {
	text string
	decl bool // a declaration (func, type, var, const, import), else a statement
}

// splitTop cuts SRC at the semicolons (explicit or inserted at line ends) that are outside of any brackets.
func splitTop(src string) []chunk {
	fset := token.NewFileSet()
	file := fset.AddFile("", fset.Base(), len(src))
	var s scanner.Scanner
	s.Init(file, []byte(src), func(token.Position, string) {}, 0)
	var out []chunk
	depth, start := 0, 0
	first := token.ILLEGAL
	emit := func(end int) {
		if end > len(src) {
			end = len(src)
		}
		if start < end {
			text := strings.TrimSpace(src[start:end])
			if text != "" {
				out = append(out, chunk{text: text, decl: isDecl(text, first)})
			}
		}
	}
	for {
		pos, tok, _ := s.Scan()
		if tok == token.EOF {
			break
		}
		if first == token.ILLEGAL {
			first = tok
		}
		switch tok {
		case token.LPAREN, token.LBRACK, token.LBRACE:
			depth++
		case token.RPAREN, token.RBRACK, token.RBRACE:
			depth--
		case token.SEMICOLON:
			if depth <= 0 {
				off := file.Offset(pos)
				emit(off)
				start = off + 1
				first = token.ILLEGAL
				depth = 0
			}
		}
	}
	emit(len(src))
	return out
}

// isDecl tells whether TEXT, which starts with the token FIRST, is a declaration. A text starting with func may also be a
// call of a function literal; a successful parse as a file settles it.
func isDecl(text string, first token.Token) bool {
	switch first {
	case token.CONST, token.TYPE, token.VAR, token.IMPORT:
		return true
	case token.FUNC:
		f, err := parser.ParseFile(token.NewFileSet(), "", "package p;"+text, 0)
		return err == nil && len(f.Decls) > 0
	}
	return false
}

// isExprStmt tells whether TEXT is one expression statement.
func isExprStmt(text string) bool {
	f, err := parser.ParseFile(token.NewFileSet(), "", "package p\nfunc _() {\n"+text+"\n}", 0)
	if err != nil || len(f.Decls) != 1 {
		return false
	}
	fd, ok := f.Decls[0].(*ast.FuncDecl)
	if !ok || len(fd.Body.List) != 1 {
		return false
	}
	_, ok = fd.Body.List[0].(*ast.ExprStmt)
	return ok
}

// group is what one call of yaegi's Eval evaluates.
type group struct {
	text    string
	decl    bool
	capture bool // the text is one expression whose value is wanted
}

func groups(chunks []chunk) []group {
	var out []group
	for i, c := range chunks {
		if !c.decl && i == len(chunks)-1 {
			// the last statement stands alone: when it is an expression, its value is the value of the source
			out = append(out, group{text: c.text, capture: isExprStmt(c.text)})
			continue
		}
		if n := len(out); n > 0 && out[n-1].decl == c.decl {
			sep := "\n"
			if !c.decl {
				sep = ";\n"
			}
			out[n-1].text += sep + c.text
			continue
		}
		out = append(out, group{text: c.text, decl: c.decl})
	}
	return out
}

type compileError struct{ msg string }

func (e *compileError) Error() string { return e.msg }

type panicError struct {
	value any
	stack string
}

func (e *panicError) Error() string { return fmt.Sprint(e.value) }

// run evaluates one group; the value of a capture group is the first value that was handed to nfc.Ret.
func (in *Interp) run(g group) (res reflect.Value, err error) {
	defer func() {
		if r := recover(); r != nil { // a failure inside yaegi's compiler, outside of its own recover
			err = &compileError{msg: fmt.Sprint("internal error of the interpreter: ", r)}
		}
	}()
	g.text = in.rewriteRecover(g.text, g.decl)
	var refused string
	if g.text, refused = rewriteGo(g.text, g.decl); refused != "" {
		return reflect.Value{}, &compileError{msg: refused}
	}
	if g.decl {
		g.text = in.dropImported(g.text)
		if strings.TrimSpace(g.text) == "" {
			return reflect.Value{}, nil
		}
		if definesMain(g.text) {
			// yaegi runs a function main of the REPL's package again after every later evaluation
			return reflect.Value{}, &compileError{msg: "a function named main would run again after every evaluation; give it another name"}
		}
	}
	if g.capture {
		in.ret = nil
		var compiled bool
		compiled, err = in.inFunc("nfc.Ret(" + g.text + ",\n)")
		if err == nil {
			if len(in.ret) > 0 {
				res = reflect.ValueOf(in.ret[0])
			}
			in.ret = nil
			return res, nil
		}
		if compiled {
			return reflect.Value{}, in.runtimeErr(err)
		}
		// A statement without a value (a call of a function without results) does not compile as an argument: run it plain.
	}
	if !g.decl && definesNothing(g.text) {
		if compiled, err := in.inFunc(g.text); err != nil {
			if compiled {
				return reflect.Value{}, in.runtimeErr(err)
			}
			return reflect.Value{}, &compileError{msg: cleanCompileError(err)}
		}
		return reflect.Value{}, nil
	}
	text := g.text
	if !g.decl {
		// Yaegi treats a source that starts with `func` as declarations first and, when that does not parse, wraps it in a
		// function main that stays defined (and runs again after every later evaluation). A leading ; makes it plain statements.
		text = ";" + text
	}
	if _, err = in.eval(text); err != nil {
		return reflect.Value{}, in.runtimeErr(err)
	}
	return reflect.Value{}, nil
}

// inFunc runs statements as the body of a function that is defined and called, instead of at the top level of the
// interpreter: the temporaries of the evaluation then live in a frame that is dropped afterwards. At the top level every
// call with arguments takes a slot in yaegi's global frame for good, and the frame is copied whenever it grows, so a host
// that evaluates many snippets would get slower with each one (12000 evaluations of `1 + 1` took 2 s that way, 0.7 s as a
// function), and the host objects the temporaries refer to would stay alive. (A function literal called on the spot does
// the same as the top level: yaegi copies its frame each time.) compiled reports that the body compiled, so that an error
// is the script's panic and not a compile error.
func (in *Interp) inFunc(body string) (compiled bool, err error) {
	if _, err = in.eval("func " + runFunc + "() {\n" + body + "\n}"); err != nil {
		return false, err
	}
	_, err = in.eval(";" + runFunc + "()")
	return true, err
}

// runFunc is the name of the function inFunc defines; a script should not use it.
const runFunc = "nfc_run"

// runtimeErr is the error of an Eval that compiled: a panic of the script, else (an error of yaegi's own) a compile error.
func (in *Interp) runtimeErr(err error) error {
	var p interp.Panic
	if errors.As(err, &p) {
		return in.panicErr(p)
	}
	return &compileError{msg: cleanCompileError(err)}
}

func (in *Interp) panicErr(p interp.Panic) error {
	v := p.Value
	if rv, ok := v.(reflect.Value); ok {
		if rv.IsValid() && rv.CanInterface() {
			v = rv.Interface()
		} else {
			v = nil
		}
	}
	return &panicError{value: v, stack: string(p.Stack)}
}

// evalSource evaluates SRC and returns the value of its last expression statement (invalid when there is none).
func (in *Interp) evalSource(src string) (reflect.Value, error) {
	var res reflect.Value
	if firstToken(src) == token.PACKAGE {
		return res, &compileError{msg: "a source is declarations or statements, not a file: leave out the package clause"}
	}
	for _, g := range groups(splitTop(src)) {
		v, err := in.run(g)
		if err != nil {
			return reflect.Value{}, err
		}
		res = v
	}
	return res, nil
}

// cleanCompileError drops the position that points into yaegi's wrapper function and rewrites the message about packages
// that are not in the whitelist.
func cleanCompileError(err error) string {
	msg := err.Error()
	if i := strings.Index(msg, "unable to find source related to: "); i >= 0 {
		rest := msg[i+len("unable to find source related to: "):]
		if j := strings.IndexByte(rest, ' '); j > 0 {
			rest = rest[:j]
		}
		if q, uerr := strconv.Unquote(strings.TrimSuffix(rest, ".")); uerr == nil {
			rest = q
		}
		return fmt.Sprintf("package %q is not available to scripts (nfcpoly's Go whitelist)", rest)
	}
	// "1:28: undefined: x", "_.go:2:1: expected ...": the line and column count yaegi's wrapper, not the script.
	if strings.HasPrefix(msg, "_.go:") {
		msg = msg[len("_.go:"):]
	}
	k := 0
	for k < len(msg) && (msg[k] >= '0' && msg[k] <= '9' || msg[k] == ':') {
		k++
	}
	if k > 0 && k < len(msg) && msg[k] == ' ' {
		msg = msg[k+1:]
	}
	return msg
}

// dropImported removes the imports that are already in force from an import declaration (scripts naturally start with
// `import "strings"`, and yaegi refuses to import a package twice).
func (in *Interp) dropImported(text string) string {
	if !strings.HasPrefix(strings.TrimSpace(text), "import") && !strings.Contains(text, "\nimport") {
		return text
	}
	var keep []string
	var rest []string
	for _, c := range splitTop(text) {
		if !strings.HasPrefix(c.text, "import") {
			rest = append(rest, c.text)
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), "", "package p;"+c.text, parser.ImportsOnly)
		if err != nil {
			rest = append(rest, c.text) // let yaegi report it
			continue
		}
		for _, imp := range f.Imports {
			path, _ := strconv.Unquote(imp.Path.Value)
			name := ""
			if imp.Name != nil {
				name = imp.Name.Name
			}
			if name == "" && in.imported[path] {
				continue
			}
			if name == "" {
				keep = append(keep, "import "+imp.Path.Value)
			} else {
				keep = append(keep, "import "+name+" "+imp.Path.Value)
			}
		}
	}
	return strings.Join(append(keep, rest...), "\n")
}

// definesMain tells whether the declarations include a function main (not a method).
func definesMain(text string) bool {
	f, err := parser.ParseFile(token.NewFileSet(), "", "package p\n"+text, 0)
	if err != nil {
		return false
	}
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name.Name == "main" {
			return true
		}
	}
	return false
}

// definesNothing tells whether the statements declare no variable, type or label, so that running them inside a function
// (inFunc) changes nothing the next evaluation could see.
func definesNothing(text string) bool {
	f, err := parser.ParseFile(token.NewFileSet(), "", "package p\nfunc _() {\n"+text+"\n}", 0)
	if err != nil || len(f.Decls) != 1 {
		return false
	}
	fd, ok := f.Decls[0].(*ast.FuncDecl)
	if !ok {
		return false
	}
	for _, st := range fd.Body.List {
		switch x := st.(type) {
		case *ast.DeclStmt, *ast.LabeledStmt, *ast.ReturnStmt, *ast.BranchStmt:
			return false
		case *ast.AssignStmt:
			if x.Tok == token.DEFINE {
				return false
			}
		}
	}
	return true
}

// firstToken is the first token of SRC (ILLEGAL when there is none).
func firstToken(src string) token.Token {
	fset := token.NewFileSet()
	file := fset.AddFile("", fset.Base(), len(src))
	var s scanner.Scanner
	s.Init(file, []byte(src), func(token.Position, string) {}, 0)
	_, tok, _ := s.Scan()
	if tok == token.EOF {
		return token.ILLEGAL
	}
	return tok
}

// eval is yaegi's Eval followed by dropping what it keeps of every snippet it compiled: it appends the root of the syntax tree
// to a list that only its debugger reads (`roots`), and every scope it opens to the list of children of the package scope
// (`child`, which nothing reads), so that a host that evaluates many snippets grows by about 12 kB per evaluation, and by
// 6 kB more for each function the snippets define. Both fields are internal to yaegi v0.16.1; when they are not there (another
// version) nothing is dropped and nothing else changes.
func (in *Interp) eval(src string) (reflect.Value, error) {
	v, err := in.itp.Eval(src)
	in.dropTrees()
	return v, err
}

func (in *Interp) dropTrees() {
	wipe := func(v reflect.Value, name string) {
		if f := v.FieldByName(name); f.IsValid() && f.Kind() == reflect.Slice && f.CanAddr() {
			reflect.NewAt(f.Type(), unsafe.Pointer(f.UnsafeAddr())).Elem().Set(reflect.Zero(f.Type()))
		}
	}
	it := reflect.ValueOf(in.itp).Elem()
	wipe(it, "roots")
	if m := it.FieldByName("scopes"); m.IsValid() && m.Kind() == reflect.Map {
		for r := m.MapRange(); r.Next(); {
			if s := r.Value(); s.Kind() == reflect.Pointer && !s.IsNil() {
				wipe(s.Elem(), "child")
			}
		}
	}
	if u := it.FieldByName("universe"); u.IsValid() && u.Kind() == reflect.Pointer && !u.IsNil() {
		wipe(u.Elem(), "child")
	}
}
