(translation-unit "float_neg_switch.cpp")

(function "_Z3negd"
  (returns double)
  (params (param "x" double))
  (block
    (return (negate double (var double "x")))))

(function "_Z4negff"
  (returns float)
  (params (param "x" float))
  (block
    (return (negate float (var float "x")))))

(function "_Z8classifyi"
  (returns int)
  (params (param "k" int))
  (block
    (switch (var int "k")
      (block
        (case 0)
        (return (const int 1))
        (case 1)
        (return (const int 2))
        (case 5)
        (return (const int 10))
        (default)
        (return (const int 100))))))

(function "main"
  (returns int)
  (params)
  (block
    (local "s" int)
    (local "d" double)
    (local "signbit_ok" bool)
    (decl "s" int)
    (init "s" constant 0)
    (block
      (local "i" int)
      (decl "i" int)
      (init "i" constant 0)
      (for
        (cond (lt int (var int "i") (const int 4)))
        (step (pre_incr int (var int "i")))
        (block
          (expr (add_assign int (var int "s") (call int (routine (ptr (fn int (int))) "_Z8classifyi") (question int (eq int (var int "i") (const int 3)) (const int 5) (var int "i"))))))))
    (decl "d" double)
    (init "d" expression (add double (call double (routine (ptr (fn double (double))) "_Z3negd") (const double 2.5)) (const double 2.5)))
    (decl "signbit_ok" bool)
    (init "signbit_ok" expression (cast bool (lt int (divide double (const double 1.0) (call double (routine (ptr (fn double (double))) "_Z3negd") (const double 0.0))) (const double 0.0))))
    (return (question int (land int (land int (land int (eq int (var int "s") (const int 113)) (eq int (var double "d") (const double 0.0))) (eq int (call float (routine (ptr (fn float (float))) "_Z4negff") (const float 1.5)) (const float -1.5))) (var bool "signbit_ok")) (const int 42) (const int 1)))))
