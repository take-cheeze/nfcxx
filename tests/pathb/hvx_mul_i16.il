(translation-unit "hvx_mul_i16.cpp")

(function "_Z10mul_q4_i16PsPKsS1_i"
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
          (expr (assign short (subscript short (var (ptr short) "dst") (var int "i")) (cast short (shiftr int (multiply int (cast int (subscript short (var (ptr (const short)) "a") (var int "i"))) (cast int (subscript short (var (ptr (const short)) "b") (var int "i")))) (const int 4))))))))
    (return)))

(function "main"
  (returns int)
  (params)
  (block
    (local "tmp1" (ptr (const short)))
    (local "tmp2" (ptr (const short)))
    (local "a" (array 96 short))
    (local "b" (array 96 short))
    (local "d" (array 96 short))
    (local "acc" unsigned_int)
    (decl "a" (array 96 short))
    (decl "b" (array 96 short))
    (decl "d" (array 96 short))
    (block
      (local "i" int)
      (decl "i" int)
      (init "i" constant 0)
      (for
        (cond (lt int (var int "i") (const int 96)))
        (step (pre_incr int (var int "i")))
        (block
          (expr (assign short (subscript short (array_to_pointer (ptr short) (var (array 96 short) "a")) (var int "i")) (cast short (subtract int (multiply int (var int "i") (const int 37)) (const int 1500)))))
          (expr (assign short (subscript short (array_to_pointer (ptr short) (var (array 96 short) "b")) (var int "i")) (cast short (subtract int (const int 3000) (multiply int (var int "i") (const int 53)))))))))
    (expr (comma void (comma (ptr (const short)) (assign (ptr (const short)) (var (ptr (const short)) "tmp1") (cast (ptr (const short)) (array_to_pointer (ptr short) (var (array 96 short) "a")))) (assign (ptr (const short)) (var (ptr (const short)) "tmp2") (cast (ptr (const short)) (array_to_pointer (ptr short) (var (array 96 short) "b"))))) (call void (routine (ptr (fn void ((ptr short) (ptr (const short)) (ptr (const short)) int))) "_Z10mul_q4_i16PsPKsS1_i") (array_to_pointer (ptr short) (var (array 96 short) "d")) (var (ptr (const short)) "tmp1") (var (ptr (const short)) "tmp2") (const int 96))))
    (decl "acc" unsigned_int)
    (init "acc" constant 0)
    (block
      (local "i" int)
      (decl "i" int)
      (init "i" constant 0)
      (for
        (cond (lt int (var int "i") (const int 96)))
        (step (pre_incr int (var int "i")))
        (block
          (expr (assign unsigned_int (var unsigned_int "acc") (add unsigned_int (multiply unsigned_int (var unsigned_int "acc") (const unsigned_int 31)) (cast unsigned_int (cast unsigned_short (subscript short (array_to_pointer (ptr short) (var (array 96 short) "d")) (var int "i"))))))))))
    (return (cast int (and unsigned_int (var unsigned_int "acc") (const unsigned_int 255))))))
