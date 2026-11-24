; ModuleID = 'LLVMDialectModule'
source_filename = "LLVMDialectModule"


define internal { i8*, i8*, i32, [4 x i32], [4 x i32] } @__impl_generated_0(i8* %0, i8* noalias %1, i32 %2, i32 %3, i32 %4, i32 %5, i32 %6, i32 %7, i32 %8, i32 %9, i32 %10, i8* %11, i8* noalias %12, i32 %13, i32 %14, i32 %15, i32 %16, i32 %17, i32 %18, i32 %19, i32 %20, i32 %21) {
  %23 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } poison, i8* %11, 0
  %24 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %23, i8* %12, 1
  %25 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %24, i32 0, 2
  %26 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %25, i32 1, 3, 0
  %27 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %26, i32 16, 4, 0
  %28 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %27, i32 1, 3, 1
  %29 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %28, i32 16, 4, 1
  %30 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %29, i32 1, 3, 2
  %31 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %30, i32 16, 4, 2
  %32 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %31, i32 16, 3, 3
  %33 = insertvalue { i8*, i8*, i32, [4 x i32], [4 x i32] } %32, i32 1, 4, 3
  br label %34

34:                                               ; preds = %37, %22
  %35 = phi i32 [ %44, %37 ], [ 0, %22 ]
  %36 = icmp slt i32 %35, 16
  br i1 %36, label %37, label %45

37:                                               ; preds = %34
  %38 = add nuw nsw i32 0, %35
  %tc67 = bitcast i8* %1 to half*
  %tc68 = getelementptr inbounds half, half* %tc67, i32 %38
  %39 = bitcast half* %tc68 to i8*
  %tc69 = bitcast i8* %39 to half*
  %40 = load half, half* %tc69, align 2
  %mx1.c = fcmp ogt half %40, 0xH0000
  %41 = select i1 %mx1.c, half %40, half 0xH0000
  %42 = add nuw nsw i32 0, %35
  %tc70 = bitcast i8* %12 to half*
  %tc71 = getelementptr inbounds half, half* %tc70, i32 %42
  %43 = bitcast half* %tc71 to i8*
  %tc72 = bitcast i8* %43 to half*
  store half %41, half* %tc72, align 2
  %44 = add i32 %35, 1
  br label %34

45:                                               ; preds = %34
  ret { i8*, i8*, i32, [4 x i32], [4 x i32] } %33
}



!llvm.module.flags = !{!0}

!0 = !{i32 2, !"Debug Info Version", i32 3}

define void @generated_0(i32 %lp) {
entry:
  %pin = inttoptr i32 %lp to i32*
  %ia = load i32, i32* %pin, align 4
  %out_rec = add i32 %lp, 40
  %pout = inttoptr i32 %out_rec to i32*
  %oa = load i32, i32* %pout, align 4
  %inb = inttoptr i32 %ia to i8*
  %outb = inttoptr i32 %oa to i8*
  call { i8*, i8*, i32, [4 x i32], [4 x i32] } @__impl_generated_0(i8* %inb, i8* %inb, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i8* %outb, i8* %outb, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0)
  ret void
}
