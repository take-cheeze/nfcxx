(translation-unit "struct_libc.cpp")

(function "_Z4makei"
  (returns (struct "V"))
  (params (param "x" int))
  (block
    (local "tmp1" (struct "V"))
    (block
      (expr (assign int (dot_field int (var (struct "V") "tmp1") (field "a")) (var int "x")))
      (expr (assign int (dot_field int (var (struct "V") "tmp1") (field "b")) (add int (var int "x") (const int 1))))
      (expr (assign int (dot_field int (var (struct "V") "tmp1") (field "c")) (add int (var int "x") (const int 2))))
      (return (var (struct "V") "tmp1")))))

(function "_Z3sum1V"
  (returns int)
  (params (param "v" (struct "V")))
  (block
    (return (add int (add int (dot_field int (var (struct "V") "v") (field "a")) (dot_field int (var (struct "V") "v") (field "b"))) (dot_field int (var (struct "V") "v") (field "c"))))))

(function "main"
  (returns int)
  (params)
  (block
    (local "arr" (array 4 int))
    (local "t" int)
    (decl "arr" (array 4 int))
    (init "arr" constant (aggregate 1 2 3 4))
    (decl "t" int)
    (init "t" constant 0)
    (block
      (local "tmp2" (ptr (array 4 int)))
      (local "tmp3" (ptr int))
      (local "tmp4" (ptr int))
      (expr (assign (ptr (array 4 int)) (var (ptr (array 4 int)) "tmp2") (address_of (ptr (array 4 int)) (var (array 4 int) "arr"))))
      (expr (assign (ptr int) (var (ptr int) "tmp3") (array_to_pointer (ptr int) (indirect (array 4 int) (var (ptr (array 4 int)) "tmp2")))))
      (expr (assign (ptr int) (var (ptr int) "tmp4") (padd (ptr int) (array_to_pointer (ptr int) (indirect (array 4 int) (var (ptr (array 4 int)) "tmp2"))) (const unsigned_long 4))))
      (for
        (cond (ne int (var (ptr int) "tmp3") (var (ptr int) "tmp4")))
        (step (pre_incr (ptr int) (var (ptr int) "tmp3")))
        (block
          (local "x" int)
          (expr (assign int (var int "x") (indirect int (var (ptr int) "tmp3"))))
          (block
            (expr (add_assign int (var int "t") (var int "x")))))))
    (return (question int (land int (land int (eq int (call int (routine (ptr (fn int ((struct "V")))) "_Z3sum1V") (call (struct "V") (routine (ptr (fn (struct "V") (int))) "_Z4makei") (const int 2))) (const int 9)) (eq int (var int "t") (const int 10))) (const int 1)) (const int 9) (const int 1)))))
