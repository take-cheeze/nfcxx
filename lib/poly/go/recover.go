package main

// recover() in scripts.
//
// In yaegi the value of recover() after a script's own panic(x) is a reflect.Value holding x, which defeats r.(string) and
// r.(error) (yaegi v0.16.1 and its master of February 2026 alike; the builtin is compiled inside yaegi, so no hook reaches it).
// The bridge makes it behave as in Go by wrapping each call of the builtin in nfc.Unwrap: the source is parsed with go/parser and
// each `recover()` that refers to the builtin gets "nfc.Unwrap(" in front of it and ")" after it, at the byte offsets of the
// call (nothing is printed back, so the rest of the text, and the line numbers of any error, stay as written). A call is left
// alone when it is the operand of `defer` or `go` (`defer recover()` does not recover anything in Go, and wrapping it
// would call recover at the wrong time), when the identifier is declared in the same text, and for the rest of the
// interpreter's life once the script has declared its own top-level `recover` (then the identifier is not the builtin).
// A text that does not parse is returned as it is: yaegi reports the error.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"regexp"
	"strings"
)

var recoverCall = regexp.MustCompile(`\brecover\s*\(`)

func (in *Interp) rewriteRecover(text string, decl bool) string {
	if in.recoverShadowed || !recoverCall.MatchString(text) {
		return text
	}
	prefix := "package p\n"
	suffix := ""
	if !decl {
		prefix, suffix = "package p\nfunc _() {\n", "\n}"
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", prefix+text+suffix, 0)
	if err != nil {
		return text
	}
	if declaresRecover(f, decl) {
		in.recoverShadowed = true
		return text
	}
	skip := map[*ast.CallExpr]bool{}
	var spans [][2]int
	ast.Inspect(f, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.DeferStmt:
			skip[x.Call] = true
		case *ast.GoStmt:
			skip[x.Call] = true
		case *ast.CallExpr:
			if id, ok := x.Fun.(*ast.Ident); ok && id.Name == "recover" && id.Obj == nil && len(x.Args) == 0 && !skip[x] {
				spans = append(spans, [2]int{fset.Position(x.Pos()).Offset - len(prefix), fset.Position(x.End()).Offset - len(prefix)})
			}
		}
		return true
	})
	if len(spans) == 0 {
		return text
	}
	var sb strings.Builder
	last := 0
	for _, sp := range spans {
		if sp[0] < last || sp[1] > len(text) {
			return text // overlapping or out of range: not a shape this understands
		}
		sb.WriteString(text[last:sp[0]])
		sb.WriteString("nfc.Unwrap(")
		sb.WriteString(text[sp[0]:sp[1]])
		sb.WriteString(")")
		last = sp[1]
	}
	sb.WriteString(text[last:])
	return sb.String()
}

// declaresRecover tells whether the top level of the parsed text declares an identifier named recover.
func declaresRecover(f *ast.File, decl bool) bool {
	named := func(id *ast.Ident) bool { return id != nil && id.Name == "recover" }
	check := func(d ast.Decl) bool {
		switch x := d.(type) {
		case *ast.FuncDecl:
			return x.Recv == nil && named(x.Name)
		case *ast.GenDecl:
			for _, sp := range x.Specs {
				switch s := sp.(type) {
				case *ast.ValueSpec:
					for _, id := range s.Names {
						if named(id) {
							return true
						}
					}
				case *ast.TypeSpec:
					if named(s.Name) {
						return true
					}
				}
			}
		}
		return false
	}
	if decl {
		for _, d := range f.Decls {
			if check(d) {
				return true
			}
		}
		return false
	}
	if len(f.Decls) != 1 {
		return false
	}
	fd, ok := f.Decls[0].(*ast.FuncDecl)
	if !ok {
		return false
	}
	for _, st := range fd.Body.List {
		switch x := st.(type) {
		case *ast.DeclStmt:
			if check(x.Decl) {
				return true
			}
		case *ast.AssignStmt:
			if x.Tok == token.DEFINE {
				for _, l := range x.Lhs {
					if id, ok := l.(*ast.Ident); ok && named(id) {
						return true
					}
				}
			}
		}
	}
	return false
}
