; LLVM IR, as clang -S -emit-llvm writes it (the subset of docs/notes/pathb-llvm.md): scripts/llvm-to-pathb.rb turns it
; into the nfcxx IR. main() sums fib(0) .. fib(9) in a loop of phi nodes and returns 88.
source_filename = "fib.c"
target triple = "x86_64-pc-linux-gnu"

define i32 @fib(i32 %n) {
entry:
  %small = icmp slt i32 %n, 2
  br i1 %small, label %done, label %recurse

recurse:
  %n1 = sub nsw i32 %n, 1
  %a = call i32 @fib(i32 %n1)
  %n2 = sub nsw i32 %n, 2
  %b = call i32 @fib(i32 %n2)
  %sum = add nsw i32 %a, %b
  br label %done

done:
  %r = phi i32 [ %n, %entry ], [ %sum, %recurse ]
  ret i32 %r
}

define i32 @main() {
entry:
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %loop ]
  %s = phi i32 [ 0, %entry ], [ %s1, %loop ]
  %f = call i32 @fib(i32 %i)
  %s1 = add nsw i32 %s, %f
  %next = add nsw i32 %i, 1
  %more = icmp slt i32 %next, 10
  br i1 %more, label %loop, label %exit

exit:
  ret i32 %s1
}
