// Go, through TinyGo's LLVM IR (no garbage collector: -gc=none, so nothing may be allocated on the heap; no
// goroutines: -scheduler=none) and llvm-to-pathb.rb. println writes to the Console through the write binding, and
// os.Exit's status is the result of the run (a program that returns from main gives 0).
package main

import "os"

type shape interface{ area() int }

type rect struct{ w, h int }
type square int

func (r rect) area() int   { return r.w * r.h }
func (s square) area() int { return int(s) * int(s) }

func sort(v []int) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && v[j-1] > v[j]; j-- {
			v[j-1], v[j] = v[j], v[j-1]
		}
	}
}

func main() {
	v := [...]int{9, 3, 7, 1, 5}
	sort(v[:])
	weighted := 0
	for i, x := range v {
		weighted += (i + 1) * x
	}
	shapes := [2]shape{rect{3, 4}, square(5)}
	total := 0
	for _, s := range shapes {
		total += s.area()
	}
	println("hello from go:", weighted, total)
	os.Exit(weighted + total) // 95 + 37
}
