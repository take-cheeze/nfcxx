package main

import (
	"path"
	"reflect"
	"sort"

	"github.com/traefik/yaegi/stdlib"
)

// The standard packages a script can import: pure computation and text handling, no files, no processes, no network,
// no unsafe, no reflection, no runtime hooks. The scripts get exactly these (and the package nfc of the bridge); the rest
// of yaegi's stdlib.Symbols is not handed to the interpreter. Every one is imported before the first script runs.
var allowed = []string{
	"bufio", "bytes", "container/heap", "container/list", "context", "encoding/base64", "encoding/hex", "encoding/json",
	"errors", "fmt", "io", "math", "math/bits", "math/rand", "path", "regexp", "sort", "strconv", "strings", "sync",
	"sync/atomic", "time", "unicode", "unicode/utf8",
}

// The generic packages are not binary symbols (Go cannot export generic functions to a reflection based interpreter): yaegi
// compiles its own Go source of them when the standard symbols are loaded (interp.Use of "fmt/fmt").
var sourcePackages = []string{"cmp", "maps", "slices"}

// Symbols dropped from an allowed package because they reach the file system. (fmt.Scan and its relatives stay: yaegi
// points them at the interpreter's own standard input, which is empty.)
var dropped = map[string][]string{
	"time/time": {"LoadLocation", "LoadLocationFromTZData"}, // read the zoneinfo files
}

func whitelist() (map[string]map[string]reflect.Value, []string) {
	exports := map[string]map[string]reflect.Value{}
	var imports []string
	for _, p := range allowed {
		key := p + "/" + path.Base(p)
		syms, ok := stdlib.Symbols[key]
		if !ok {
			continue
		}
		cp := make(map[string]reflect.Value, len(syms))
		for k, v := range syms {
			cp[k] = v
		}
		for _, d := range dropped[key] {
			delete(cp, d)
		}
		exports[key] = cp
		imports = append(imports, p)
	}
	sort.Strings(imports)
	return exports, imports
}
