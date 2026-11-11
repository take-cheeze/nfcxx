; LLVM IR with a struct type and the puts binding: points in a global array of %point, read through getelementptr
; with struct indices (the field offsets come from the x86-64 layout rules), and a string printed with puts.
; main() returns the sum of x * y over the points: 1*2 + 3*4 + 5*6 = 44.
source_filename = "points.c"
target triple = "x86_64-pc-linux-gnu"

%point = type { i32, i32 }

@points = internal global [3 x %point] [%point { i32 1, i32 2 }, %point { i32 3, i32 4 }, %point { i32 5, i32 6 }]
@msg = private constant [16 x i8] c"hello from llvm\00"

declare i32 @puts(ptr)

define i32 @main() {
entry:
  %r = call i32 @puts(ptr @msg)
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %s = phi i32 [ 0, %entry ], [ %s1, %loop ]
  %px = getelementptr inbounds [3 x %point], ptr @points, i64 0, i64 %i, i32 0
  %py = getelementptr inbounds [3 x %point], ptr @points, i64 0, i64 %i, i32 1
  %x = load i32, ptr %px
  %y = load i32, ptr %py
  %xy = mul nsw i32 %x, %y
  %s1 = add nsw i32 %s, %xy
  %next = add i64 %i, 1
  %more = icmp ult i64 %next, 3
  br i1 %more, label %loop, label %exit

exit:
  ret i32 %s1
}
