// Go: fmt. Println and Printf with structs, slices, maps and floats, and errors with fmt.Errorf. fmt makes the
// module large (about 640 KB) and the compile slow (about 20 s on the live server).
package main

import (
	"errors"
	"fmt"
	"strconv"
)

type point struct{ X, Y int }

func (p point) String() string { return fmt.Sprintf("(%d, %d)", p.X, p.Y) }

var errEmpty = errors.New("empty input")

func parse(s string) (int, error) {
	if s == "" {
		return 0, errEmpty
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("parse %q: %w", s, err)
	}
	return n, nil
}

func main() {
	fmt.Println("hello from fmt", 42, 2.5, true)
	fmt.Println(point{1, 2}, []int{3, 4, 5}, map[string]int{"a": 1})
	fmt.Printf("%-6s|%6.2f|%x\n", "pi", 3.14159, 255)
	for _, s := range []string{"12", "", "x"} {
		if n, err := parse(s); err != nil {
			fmt.Println("error:", err, errors.Is(err, errEmpty))
		} else {
			fmt.Println("parsed", n)
		}
	}
}
