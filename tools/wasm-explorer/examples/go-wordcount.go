// Go: maps, slices, sort and strings. A word count over a text: the words are split with strings.Fields, counted
// in a map, and printed in order of count with sort.Slice. os.Exit's status is the result of the run.
package main

import (
	"os"
	"sort"
	"strings"
)

const text = `the wasm explorer compiles go to the nfcxx ir
and the ir to wasm and the page runs the wasm`

type entry struct {
	word  string
	count int
}

func main() {
	counts := map[string]int{}
	for _, w := range strings.Fields(text) {
		counts[w]++
	}
	var entries []entry
	for w, c := range counts {
		entries = append(entries, entry{w, c})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].count != entries[j].count {
			return entries[i].count > entries[j].count
		}
		return entries[i].word < entries[j].word
	})
	for _, e := range entries[:4] {
		println(e.word, e.count)
	}
	println("distinct words:", len(entries))
	os.Exit(len(entries)*10 + entries[0].count) // 11 distinct words, "the" 5 times
}
