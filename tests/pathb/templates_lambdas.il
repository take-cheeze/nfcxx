(translation-unit "templates_lambdas.cpp")

(function "main"
  (returns int)
  (params)
  (block
    (local "p" (struct "P"))
    (local "f" (struct "_ZZ4mainEUliE_"))
    (decl "p" (struct "P"))
    (init "p" constant (aggregate 0 4))
    (expr (assign int (dot_field int (var (struct "P") "p") (field "x")) (call int (routine (ptr (fn int (int int))) "_Z3addIiET_S0_S0_") (const int 1) (const int 2))))
    (decl "f" (struct "_ZZ4mainEUliE_"))
    (expr (assign (ptr (struct "P")) (dot_field (ptr (struct "P")) (var (struct "_ZZ4mainEUliE_") "f") (field "p")) (address_of (ptr (struct "P")) (var (struct "P") "p"))))
    (return (call int (routine (ptr (fn int ((ptr (const (struct "_ZZ4mainEUliE_"))) int))) "_ZZ4mainENKUliE_clEi") (address_of (ptr (const (struct "_ZZ4mainEUliE_"))) (lvalue_adjust (const (struct "_ZZ4mainEUliE_")) (var (struct "_ZZ4mainEUliE_") "f"))) (const int 5)))))

(function "_Z3addIiET_S0_S0_"
  (returns int)
  (params (param "a" int) (param "b" int))
  (block
    (return (add int (var int "a") (var int "b")))))

(function "_ZZ4mainENKUliE_clEi"
  (returns int)
  (params (param "tmp1" (const (ptr (const (struct "_ZZ4mainEUliE_"))))) (param "k" int))
  (static)
  (block
    (return (add int (call int (routine (ptr (fn int ((ptr (const (struct "P")))))) "_ZNK1P3sumEv") (cast (ptr (const (struct "P"))) (points_to_field (ptr (struct "P")) (var (ptr (const (struct "_ZZ4mainEUliE_"))) "tmp1") (field "p")))) (var int "k")))))

(function "_ZNK1P3sumEv"
  (returns int)
  (params (param "tmp2" (const (ptr (const (struct "P"))))))
  (block
    (return (add int (points_to_field int (var (ptr (const (struct "P"))) "tmp2") (field "x")) (points_to_field int (var (ptr (const (struct "P"))) "tmp2") (field "y"))))))
