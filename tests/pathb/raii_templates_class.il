(translation-unit "raii_templates_class.cpp")
(global "live" int)
(global "__eh_curr_region" unsigned_short)
(global "__curr_eh_stack_entry" (ptr (struct "__C7")))

(function "_Z1fv"
  (returns int)
  (params)
  (block
    (local "tmp1" (array 2 (ptr void)))
    (local "tmp2" int)
    (local "tmp3" (struct "__C7"))
    (local "a" (struct "_Z3BoxIiE"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp3") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp3"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp3") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C8")) (var (array 2 (struct "__C8")) "tmp4"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (decl "a" (struct "_Z3BoxIiE"))
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE")) int))) "_ZN3BoxIiEC1Ei") (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a")) (const int 3)))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a")))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (block
      (local "b" (struct "_Z3BoxIlE"))
      (decl "b" (struct "_Z3BoxIlE"))
      (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE")) long))) "_ZN3BoxIlEC1El") (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b")) (const long 4)))
      (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1")) (const unsigned_long 1)) (cast (ptr void) (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b")))))
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 1)))
      (if (ne int (var int "live") (const int 2))
        (block
          (block
            (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
            (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE"))))) "_ZN3BoxIlED1Ev") (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b"))))
            (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
            (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE"))))) "_ZN3BoxIiED1Ev") (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a"))))
            (block
              (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "saved_region_number"))))
              (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp3") (field "next"))))
              (return (const int -1))))))
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
      (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE"))))) "_ZN3BoxIlED1Ev") (address_of (ptr (struct "_Z3BoxIlE")) (var (struct "_Z3BoxIlE") "b")))))
    (block
      (expr (assign int (var int "tmp2") (question int (eq int (var int "live") (const int 1)) (const int 7) (const int -2))))
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
      (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE"))))) "_ZN3BoxIiED1Ev") (address_of (ptr (struct "_Z3BoxIiE")) (var (struct "_Z3BoxIiE") "a"))))
      (block
        (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "saved_region_number"))))
        (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp3") (field "next"))))
        (return (var int "tmp2"))))))

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
  (params (param "tmp5" (const (ptr (struct "_Z3BoxIiE")))) (param "x" int))
  (block
    (expr (assign int (points_to_field int (var (ptr (struct "_Z3BoxIiE")) "tmp5") (field "v")) (var int "x")))
    (expr (pre_incr int (var int "live")))
    (return)))

(function "_ZN3BoxIiEC2Ei"
  (returns void)
  (params (param "tmp6" (const (ptr (struct "_Z3BoxIiE")))) (param "tmp7" int))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE")) int))) "_ZN3BoxIiEC1Ei") (var (ptr (struct "_Z3BoxIiE")) "tmp6") (var int "tmp7")))
    (return)))

(function "_ZN3BoxIiED1Ev"
  (returns void)
  (params (param "tmp8" (const (ptr (struct "_Z3BoxIiE")))))
  (block
    (local "tmp9" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp9") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp9"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp9") (field "kind")) (const unsigned_char 6)))
    (expr (pre_decr int (var int "live")))
    (block
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp9") (field "next"))))
      (return))))

(function "_ZN3BoxIiED2Ev"
  (returns void)
  (params (param "tmp10" (const (ptr (struct "_Z3BoxIiE")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIiE"))))) "_ZN3BoxIiED1Ev") (var (ptr (struct "_Z3BoxIiE")) "tmp10")))
    (return)))

(function "_ZN3BoxIlEC1El"
  (returns void)
  (params (param "tmp11" (const (ptr (struct "_Z3BoxIlE")))) (param "x" long))
  (block
    (expr (assign long (points_to_field long (var (ptr (struct "_Z3BoxIlE")) "tmp11") (field "v")) (var long "x")))
    (expr (pre_incr int (var int "live")))
    (return)))

(function "_ZN3BoxIlEC2El"
  (returns void)
  (params (param "tmp12" (const (ptr (struct "_Z3BoxIlE")))) (param "tmp13" long))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE")) long))) "_ZN3BoxIlEC1El") (var (ptr (struct "_Z3BoxIlE")) "tmp12") (var long "tmp13")))
    (return)))

(function "_ZN3BoxIlED1Ev"
  (returns void)
  (params (param "tmp14" (const (ptr (struct "_Z3BoxIlE")))))
  (block
    (local "tmp15" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp15") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp15"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp15") (field "kind")) (const unsigned_char 6)))
    (expr (pre_decr int (var int "live")))
    (block
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp15") (field "next"))))
      (return))))

(function "_ZN3BoxIlED2Ev"
  (returns void)
  (params (param "tmp16" (const (ptr (struct "_Z3BoxIlE")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "_Z3BoxIlE"))))) "_ZN3BoxIlED1Ev") (var (ptr (struct "_Z3BoxIlE")) "tmp16")))
    (return)))
