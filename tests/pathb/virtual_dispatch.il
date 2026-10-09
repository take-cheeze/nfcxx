(translation-unit "virtual_dispatch.cpp")
(global "_ZTV1V" (const (array 5 (const long))))
(global "__curr_eh_stack_entry" (ptr (struct "__C8")))
(global "_ZTV1W" (const (array 5 (const long))))
(global "_ZTV1X" (const (array 5 (const long))))
(global "__eh_curr_region" unsigned_short)
(global "_ZTI1V" (const (struct "__class_type_info")))
(global "_ZTI1W" (const (struct "__si_class_type_info")))
(global "_ZTI1X" (const (struct "__si_class_type_info")))
(global "_ZTVN10__cxxabiv117__class_type_infoE" (const (array 0 (const long))))
(global "_ZTS1V" (const (array 3 (const char))))
(global "_ZTVN10__cxxabiv120__si_class_type_infoE" (const (array 0 (const long))))
(global "_ZTS1W" (const (array 3 (const char))))
(global "_ZTS1X" (const (array 3 (const char))))

(function "_Z1hRK1V"
  (returns int)
  (params (param "v" (ptr (const (struct "V")))))
  (block
    (return (call int (indirect (ptr (fn int ((ptr (const (struct "V")))))) (cast (ptr (ptr (fn int ((ptr (const (struct "V"))))))) (padd (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (const (struct "V"))) "v") (field "__vptr")) (const int 0)))) (var (ptr (const (struct "V"))) "v")))))

(function "main"
  (returns int)
  (params)
  (block
    (local "tmp1" (array 2 (ptr void)))
    (local "tmp2" int)
    (local "tmp3" (struct "__C8"))
    (local "w" (struct "W"))
    (local "x" (struct "X"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp3") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp3"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp3") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C2")) (dot_field (ptr (struct "__C2")) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp3") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C2")) (var (array 2 (struct "__C2")) "tmp4"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp3") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp3") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (decl "w" (struct "W"))
    (init "w" constant (aggregate (aggregate (address (variable "_ZTV1W") 16))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "W")) (var (struct "W") "w")))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (decl "x" (struct "X"))
    (init "x" constant (aggregate (aggregate (aggregate (address (variable "_ZTV1X") 16)))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1")) (const unsigned_long 1)) (cast (ptr void) (address_of (ptr (struct "X")) (var (struct "X") "x")))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 1)))
    (block
      (expr (assign int (var int "tmp2") (add int (multiply int (call int (routine (ptr (fn int ((ptr (const (struct "V")))))) "_Z1hRK1V") (cast (ptr (const (struct "V"))) (address_of (ptr (struct "V")) (dot_field (struct "V") (var (struct "W") "w") (field "__b_1V"))))) (const int 10)) (call int (routine (ptr (fn int ((ptr (const (struct "V")))))) "_Z1hRK1V") (cast (ptr (const (struct "V"))) (address_of (ptr (struct "V")) (dot_field (struct "V") (dot_field (struct "W") (var (struct "X") "x") (field "__b_1W")) (field "__b_1V"))))))))
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
      (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (address_of (ptr (struct "X")) (var (struct "X") "x"))))
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
      (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (address_of (ptr (struct "W")) (var (struct "W") "w"))))
      (block
        (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp3") (field "variant")) (field "function")) (field "saved_region_number"))))
        (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp3") (field "next"))))
        (return (var int "tmp2"))))))

(function "_ZNK1V1kEv"
  (returns int)
  (params (param "tmp5" (const (ptr (const (struct "V"))))))
  (block
    (return (const int 1))))

(function "_ZN1VD1Ev"
  (returns void)
  (params (param "tmp6" (const (ptr (struct "V")))))
  (block
    (local "tmp7" (struct "__C8"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp7") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp7"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp7") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (struct "V")) "tmp6") (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1V") 16))))
    (block
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp7") (field "next"))))
      (return))))

(function "_ZN1VD0Ev"
  (returns void)
  (params (param "tmp8" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VD1Ev") (var (ptr (struct "V")) "tmp8")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "V")) "tmp8")) (const unsigned_long 8)))
    (return)))

(function "_ZN1VD2Ev"
  (returns void)
  (params (param "tmp9" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VD1Ev") (var (ptr (struct "V")) "tmp9")))
    (return)))

(function "_ZN1VC1Ev"
  (returns void)
  (params (param "tmp10" (const (ptr (struct "V")))))
  (block
    (local "tmp11" (struct "__C8"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp11") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp11"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp11") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (struct "V")) "tmp10") (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1V") 16))))
    (block
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp11") (field "next"))))
      (return))))

(function "_ZN1VC2Ev"
  (returns void)
  (params (param "tmp12" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VC1Ev") (var (ptr (struct "V")) "tmp12")))
    (return)))

(function "_ZNK1W1kEv"
  (returns int)
  (params (param "tmp13" (const (ptr (const (struct "W"))))))
  (block
    (return (const int 2))))

(function "_ZN1WC1Ev"
  (returns void)
  (params (param "tmp14" (const (ptr (struct "W")))))
  (block
    (local "tmp15" (array 1 (ptr void)))
    (local "tmp16" (struct "__C8"))
    (local "tmp17" (struct "__C8"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp16") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp16"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp16") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp17") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp17"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp17") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C2")) (dot_field (ptr (struct "__C2")) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp17") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C2")) (var (array 1 (struct "__C2")) "tmp18"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp17") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp15"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp17") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (call void (routine (ptr (fn void ((const (ptr (struct "V")))))) "_ZN1VC2Ev") (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp14") (field "__b_1V")))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp15")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp14") (field "__b_1V"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp14") (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1W") 16))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp17") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp17") (field "next"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp16") (field "next"))))
      (return))))

(function "_ZN1WC2Ev"
  (returns void)
  (params (param "tmp19" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WC1Ev") (var (ptr (struct "W")) "tmp19")))
    (return)))

(function "_ZN1WD1Ev"
  (returns void)
  (params (param "tmp20" (const (ptr (struct "W")))))
  (block
    (local "tmp21" (array 1 (ptr void)))
    (local "tmp22" (struct "__C8"))
    (local "tmp23" (struct "__C8"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp22") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp22"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp22") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp23") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp23"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp23") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C2")) (dot_field (ptr (struct "__C2")) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp23") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C2")) (var (array 1 (struct "__C2")) "tmp24"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp23") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp21"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp23") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp20") (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1W") 16))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp21")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp20") (field "__b_1V"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
      (expr (call void (routine (ptr (fn void ((const (ptr (struct "V")))))) "_ZN1VD2Ev") (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp20") (field "__b_1V"))))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp23") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp23") (field "next"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp22") (field "next"))))
      (return))))

(function "_ZN1WD0Ev"
  (returns void)
  (params (param "tmp25" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (var (ptr (struct "W")) "tmp25")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "W")) "tmp25")) (const unsigned_long 8)))
    (return)))

(function "_ZN1WD2Ev"
  (returns void)
  (params (param "tmp26" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (var (ptr (struct "W")) "tmp26")))
    (return)))

(function "_ZNK1X1kEv"
  (returns int)
  (params (param "tmp27" (const (ptr (const (struct "X"))))))
  (block
    (return (const int 3))))

(function "_ZN1XC1Ev"
  (returns void)
  (params (param "tmp28" (const (ptr (struct "X")))))
  (block
    (local "tmp29" (array 1 (ptr void)))
    (local "tmp30" (struct "__C8"))
    (local "tmp31" (struct "__C8"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp30") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp30"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp30") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp31") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp31"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp31") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C2")) (dot_field (ptr (struct "__C2")) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp31") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C2")) (var (array 1 (struct "__C2")) "tmp32"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp31") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp29"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp31") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (call void (routine (ptr (fn void ((const (ptr (struct "W")))))) "_ZN1WC2Ev") (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp28") (field "__b_1W")))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp29")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp28") (field "__b_1W"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (dot_field (struct "V") (points_to_field (struct "W") (var (ptr (struct "X")) "tmp28") (field "__b_1W")) (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1X") 16))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp31") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp31") (field "next"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp30") (field "next"))))
      (return))))

(function "_ZN1XC2Ev"
  (returns void)
  (params (param "tmp33" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XC1Ev") (var (ptr (struct "X")) "tmp33")))
    (return)))

(function "_ZN1XD1Ev"
  (returns void)
  (params (param "tmp34" (const (ptr (struct "X")))))
  (block
    (local "tmp35" (array 1 (ptr void)))
    (local "tmp36" (struct "__C8"))
    (local "tmp37" (struct "__C8"))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp36") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp36"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp36") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp37") (field "next")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C8")) (var (struct "__C8") "tmp37"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C8") "tmp37") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C2")) (dot_field (ptr (struct "__C2")) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp37") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C2")) (var (array 1 (struct "__C2")) "tmp38"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp37") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp35"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp37") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (dot_field (struct "V") (points_to_field (struct "W") (var (ptr (struct "X")) "tmp34") (field "__b_1W")) (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1X") 16))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp35")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp34") (field "__b_1W"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
      (expr (call void (routine (ptr (fn void ((const (ptr (struct "W")))))) "_ZN1WD2Ev") (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp34") (field "__b_1W"))))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C7") (var (struct "__C8") "tmp37") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp37") (field "next"))))
      (expr (assign (ptr (struct "__C8")) (var (ptr (struct "__C8")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C8")) (var (struct "__C8") "tmp36") (field "next"))))
      (return))))

(function "_ZN1XD0Ev"
  (returns void)
  (params (param "tmp39" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (var (ptr (struct "X")) "tmp39")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "X")) "tmp39")) (const unsigned_long 8)))
    (return)))

(function "_ZN1XD2Ev"
  (returns void)
  (params (param "tmp40" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (var (ptr (struct "X")) "tmp40")))
    (return)))
