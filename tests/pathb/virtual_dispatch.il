(translation-unit "virtual_dispatch.cpp")
(global "_ZTV1V" (const (array 5 (const long))))
(global "_ZTV1W" (const (array 5 (const long))))
(global "_ZTV1X" (const (array 5 (const long))))
(global "__eh_curr_region" unsigned_short)
(global "__curr_eh_stack_entry" (ptr (struct "__C7")))
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
    (local "tmp3" (struct "__C7"))
    (local "w" (struct "W"))
    (local "x" (struct "X"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp3") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp3"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp3") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C8")) (var (array 2 (struct "__C8")) "tmp4"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 2 (ptr void)) "tmp1"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
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
        (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp3") (field "variant")) (field "function")) (field "saved_region_number"))))
        (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp3") (field "next"))))
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
    (expr (assign (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (struct "V")) "tmp6") (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1V") 16))))
    (return)))

(function "_ZN1VD0Ev"
  (returns void)
  (params (param "tmp7" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VD1Ev") (var (ptr (struct "V")) "tmp7")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "V")) "tmp7")) (const unsigned_long 8)))
    (return)))

(function "_ZN1VD2Ev"
  (returns void)
  (params (param "tmp8" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VD1Ev") (var (ptr (struct "V")) "tmp8")))
    (return)))

(function "_ZN1VC1Ev"
  (returns void)
  (params (param "tmp9" (const (ptr (struct "V")))))
  (block
    (expr (assign (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (struct "V")) "tmp9") (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1V") 16))))
    (return)))

(function "_ZN1VC2Ev"
  (returns void)
  (params (param "tmp10" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VC1Ev") (var (ptr (struct "V")) "tmp10")))
    (return)))

(function "_ZNK1W1kEv"
  (returns int)
  (params (param "tmp11" (const (ptr (const (struct "W"))))))
  (block
    (return (const int 2))))

(function "_ZN1WC1Ev"
  (returns void)
  (params (param "tmp12" (const (ptr (struct "W")))))
  (block
    (local "tmp13" (array 1 (ptr void)))
    (local "tmp14" (struct "__C7"))
    (local "tmp15" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp14") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp14"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp14") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp15") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp15"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp15") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp15") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C8")) (var (array 1 (struct "__C8")) "tmp16"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp15") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp13"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp15") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (call void (routine (ptr (fn void ((const (ptr (struct "V")))))) "_ZN1VC2Ev") (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp12") (field "__b_1V")))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp13")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp12") (field "__b_1V"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp12") (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1W") 16))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp15") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp15") (field "next"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp14") (field "next"))))
      (return))))

(function "_ZN1WC2Ev"
  (returns void)
  (params (param "tmp17" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WC1Ev") (var (ptr (struct "W")) "tmp17")))
    (return)))

(function "_ZN1WD1Ev"
  (returns void)
  (params (param "tmp18" (const (ptr (struct "W")))))
  (block
    (local "tmp19" (array 1 (ptr void)))
    (local "tmp20" (struct "__C7"))
    (local "tmp21" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp20") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp20"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp20") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp21") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp21"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp21") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp21") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C8")) (var (array 1 (struct "__C8")) "tmp22"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp21") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp19"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp21") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp18") (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1W") 16))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp19")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp18") (field "__b_1V"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
      (expr (call void (routine (ptr (fn void ((const (ptr (struct "V")))))) "_ZN1VD2Ev") (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp18") (field "__b_1V"))))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp21") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp21") (field "next"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp20") (field "next"))))
      (return))))

(function "_ZN1WD0Ev"
  (returns void)
  (params (param "tmp23" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (var (ptr (struct "W")) "tmp23")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "W")) "tmp23")) (const unsigned_long 8)))
    (return)))

(function "_ZN1WD2Ev"
  (returns void)
  (params (param "tmp24" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (var (ptr (struct "W")) "tmp24")))
    (return)))

(function "_ZNK1X1kEv"
  (returns int)
  (params (param "tmp25" (const (ptr (const (struct "X"))))))
  (block
    (return (const int 3))))

(function "_ZN1XC1Ev"
  (returns void)
  (params (param "tmp26" (const (ptr (struct "X")))))
  (block
    (local "tmp27" (array 1 (ptr void)))
    (local "tmp28" (struct "__C7"))
    (local "tmp29" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp28") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp28"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp28") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp29") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp29"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp29") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp29") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C8")) (var (array 1 (struct "__C8")) "tmp30"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp29") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp27"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp29") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (call void (routine (ptr (fn void ((const (ptr (struct "W")))))) "_ZN1WC2Ev") (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp26") (field "__b_1W")))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp27")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp26") (field "__b_1W"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (dot_field (struct "V") (points_to_field (struct "W") (var (ptr (struct "X")) "tmp26") (field "__b_1W")) (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1X") 16))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp29") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp29") (field "next"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp28") (field "next"))))
      (return))))

(function "_ZN1XC2Ev"
  (returns void)
  (params (param "tmp31" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XC1Ev") (var (ptr (struct "X")) "tmp31")))
    (return)))

(function "_ZN1XD1Ev"
  (returns void)
  (params (param "tmp32" (const (ptr (struct "X")))))
  (block
    (local "tmp33" (array 1 (ptr void)))
    (local "tmp34" (struct "__C7"))
    (local "tmp35" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp34") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp34"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp34") (field "kind")) (const unsigned_char 6)))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp35") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp35"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp35") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C8")) (dot_field (ptr (struct "__C8")) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp35") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C8")) (var (array 1 (struct "__C8")) "tmp36"))))
    (expr (assign (ptr (ptr void)) (dot_field (ptr (ptr void)) (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp35") (field "variant")) (field "function")) (field "obj_table")) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp33"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp35") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (dot_field (struct "V") (points_to_field (struct "W") (var (ptr (struct "X")) "tmp32") (field "__b_1W")) (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1X") 16))))
    (expr (assign (ptr void) (subscript (ptr void) (array_to_pointer (ptr (ptr void)) (var (array 1 (ptr void)) "tmp33")) (const unsigned_long 0)) (cast (ptr void) (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp32") (field "__b_1W"))))))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
      (expr (call void (routine (ptr (fn void ((const (ptr (struct "W")))))) "_ZN1WD2Ev") (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp32") (field "__b_1W"))))))
    (block
      (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C2") (dot_field (union "__C6") (var (struct "__C7") "tmp35") (field "variant")) (field "function")) (field "saved_region_number"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp35") (field "next"))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp34") (field "next"))))
      (return))))

(function "_ZN1XD0Ev"
  (returns void)
  (params (param "tmp37" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (var (ptr (struct "X")) "tmp37")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "X")) "tmp37")) (const unsigned_long 8)))
    (return)))

(function "_ZN1XD2Ev"
  (returns void)
  (params (param "tmp38" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (var (ptr (struct "X")) "tmp38")))
    (return)))
