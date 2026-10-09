(translation-unit "hvx_add_i16.cpp")

(function "_Z7add_i16PsPKsS1_i"
  (returns void)
  (params (param "dst" (ptr short)) (param "a" (ptr (const short))) (param "b" (ptr (const short))) (param "n" int))
  (block
    (block
      (local "i" int)
      (decl "i" int)
      (init "i" constant 0)
      (for
        (cond (lt int (var int "i") (var int "n")))
        (step (pre_incr int (var int "i")))
        (block
          (expr (assign short (subscript short (var (ptr short) "dst") (var int "i")) (cast short (add int (cast int (subscript short (var (ptr (const short)) "a") (var int "i"))) (cast int (subscript short (var (ptr (const short)) "b") (var int "i"))))))))))
    (return)))

(function "main"
  (returns int)
  (params)
  (block
    (local "tmp1" (ptr (const short)))
    (local "tmp2" (ptr (const short)))
    (local "a" (array 128 short))
    (local "b" (array 128 short))
    (local "d" (array 128 short))
    (local "sum" int)
    (decl "a" (array 128 short))
    (decl "b" (array 128 short))
    (decl "d" (array 128 short))
    (block
      (local "i" int)
      (decl "i" int)
      (init "i" constant 0)
      (for
        (cond (lt int (var int "i") (const int 128)))
        (step (pre_incr int (var int "i")))
        (block
          (expr (assign short (subscript short (array_to_pointer (ptr short) (var (array 128 short) "a")) (var int "i")) (cast short (subtract int (multiply int (var int "i") (const int 3)) (const int 100)))))
          (expr (assign short (subscript short (array_to_pointer (ptr short) (var (array 128 short) "b")) (var int "i")) (cast short (subtract int (const int 1000) (multiply int (var int "i") (const int 7)))))))))
    (expr (comma void (comma (ptr (const short)) (assign (ptr (const short)) (var (ptr (const short)) "tmp1") (cast (ptr (const short)) (array_to_pointer (ptr short) (var (array 128 short) "a")))) (assign (ptr (const short)) (var (ptr (const short)) "tmp2") (cast (ptr (const short)) (array_to_pointer (ptr short) (var (array 128 short) "b"))))) (call void (routine (ptr (fn void ((ptr short) (ptr (const short)) (ptr (const short)) int))) "_Z7add_i16PsPKsS1_i") (array_to_pointer (ptr short) (var (array 128 short) "d")) (var (ptr (const short)) "tmp1") (var (ptr (const short)) "tmp2") (const int 128))))
    (decl "sum" int)
    (init "sum" constant 0)
    (block
      (local "i" int)
      (decl "i" int)
      (init "i" constant 0)
      (for
        (cond (lt int (var int "i") (const int 128)))
        (step (pre_incr int (var int "i")))
        (block
          (expr (add_assign int (var int "sum") (cast int (subscript short (array_to_pointer (ptr short) (var (array 128 short) "d")) (var int "i"))))))))
    (return (and int (shiftr int (var int "sum") (const int 8)) (const int 255)))))
