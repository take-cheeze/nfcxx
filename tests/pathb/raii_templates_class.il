(translation-unit "raii_templates_class.cpp")
(global "live" int)

(function "_Z1fv"
  (returns int)
  (params)
  (block
    (local "tmp1" int)
    (local "a" (struct "_Z3BoxIiE"))
    (expr (eh-construct 4))
    (decl "a" (struct "_Z3BoxIiE"))
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE")) int))) "_ZN3BoxIiEC1Ei") (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a")) (const int 3)))
    (expr (eh-construct 2 0))
    (block
      (local "b" (struct "_Z3BoxIlE"))
      (decl "b" (struct "_Z3BoxIlE"))
      (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE")) long))) "_ZN3BoxIlEC1El") (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b")) (const long 4)))
      (expr (eh-construct 2 1))
      (if (ne int (var int "live") (const int 2))
        (block
          (block
            (expr (eh-construct 2 0))
            (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE"))))) "_ZN3BoxIlED1Ev") (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b"))))
            (expr (eh-construct 2 65535))
            (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE"))))) "_ZN3BoxIiED1Ev") (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a"))))
            (block
              (expr (eh-construct 5))
              (return (const int -1)))
            (expr (eh-construct 3 1)))))
      (expr (eh-construct 2 0))
      (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE"))))) "_ZN3BoxIlED1Ev") (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b")))))
    (block
      (expr (assign int (var int "tmp1") (question int (eq int (var int "live") (const int 1)) (const int 7) (const int -2))))
      (expr (eh-construct 2 65535))
      (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE"))))) "_ZN3BoxIiED1Ev") (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a"))))
      (block
        (expr (eh-construct 5))
        (return (var int "tmp1"))))))

(function "main"
  (returns int)
  (params)
  (block
    (local "r" int)
    (decl "r" int)
    (init "r" expression (call int (routine (ptr (fn int ())) "_Z1fv")))
    (return (question int (eq int (var int "live") (const int 0)) (var int "r") (const int -3)))))

(function "_ZN3BoxIiEC1Ei"
  (returns void)
  (params (param "tmp2" (const (ptr (struct "_Z3BoxIiE")))) (param "x" int))
  (block
    (expr (assign int (points_to_field int (var (ptr (struct "_Z3BoxIiE")) "tmp2") (field "v")) (var int "x")))
    (expr (pre_incr int (var int "live")))
    (return)))

(function "_ZN3BoxIiEC2Ei"
  (returns void)
  (params (param "tmp3" (const (ptr (struct "_Z3BoxIiE")))) (param "tmp4" int))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE")) int))) "_ZN3BoxIiEC1Ei") (var (ptr (struct "_Z3BoxIiE")) "tmp3") (var int "tmp4")))
    (return)))

(function "_ZN3BoxIiED1Ev"
  (returns void)
  (params (param "tmp5" (const (ptr (struct "_Z3BoxIiE")))))
  (block
    (expr (pre_decr int (var int "live")))
    (return)))

(function "_ZN3BoxIiED2Ev"
  (returns void)
  (params (param "tmp6" (const (ptr (struct "_Z3BoxIiE")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE"))))) "_ZN3BoxIiED1Ev") (var (ptr (struct "_Z3BoxIiE")) "tmp6")))
    (return)))

(function "_ZN3BoxIlEC1El"
  (returns void)
  (params (param "tmp7" (const (ptr (struct "_Z3BoxIlE")))) (param "x" long))
  (block
    (expr (assign long (points_to_field long (var (ptr (struct "_Z3BoxIlE")) "tmp7") (field "v")) (var long "x")))
    (expr (pre_incr int (var int "live")))
    (return)))

(function "_ZN3BoxIlEC2El"
  (returns void)
  (params (param "tmp8" (const (ptr (struct "_Z3BoxIlE")))) (param "tmp9" long))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE")) long))) "_ZN3BoxIlEC1El") (var (ptr (struct "_Z3BoxIlE")) "tmp8") (var long "tmp9")))
    (return)))

(function "_ZN3BoxIlED1Ev"
  (returns void)
  (params (param "tmp10" (const (ptr (struct "_Z3BoxIlE")))))
  (block
    (expr (pre_decr int (var int "live")))
    (return)))

(function "_ZN3BoxIlED2Ev"
  (returns void)
  (params (param "tmp11" (const (ptr (struct "_Z3BoxIlE")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE"))))) "_ZN3BoxIlED1Ev") (var (ptr (struct "_Z3BoxIlE")) "tmp11")))
    (return)))
