(translation-unit "virtual_dispatch.cpp")
(global "_ZTV1V" (const (array 5 (const long))))
(global "_ZTV1W" (const (array 5 (const long))))
(global "_ZTV1X" (const (array 5 (const long))))
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
    (local "tmp1" int)
    (local "w" (struct "W"))
    (local "x" (struct "X"))
    (expr (eh-construct 4))
    (decl "w" (struct "W"))
    (init "w" constant (aggregate (aggregate (address (variable "_ZTV1W") 16))))
    (expr (eh-construct 2 0))
    (decl "x" (struct "X"))
    (init "x" constant (aggregate (aggregate (aggregate (address (variable "_ZTV1X") 16)))))
    (expr (eh-construct 2 1))
    (block
      (expr (assign int (var int "tmp1") (add int (multiply int (call int (routine (ptr (fn int ((ptr (const (struct "V")))))) "_Z1hRK1V") (cast (ptr (const (struct "V"))) (address_of (ptr (struct "V")) (dot_field (struct "V") (var (struct "W") "w") (field "__b_1V"))))) (const int 10)) (call int (routine (ptr (fn int ((ptr (const (struct "V")))))) "_Z1hRK1V") (cast (ptr (const (struct "V"))) (address_of (ptr (struct "V")) (dot_field (struct "V") (dot_field (struct "W") (var (struct "X") "x") (field "__b_1W")) (field "__b_1V"))))))))
      (expr (eh-construct 2 0))
      (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (address_of (ptr (struct "X")) (var (struct "X") "x"))))
      (expr (eh-construct 2 65535))
      (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (address_of (ptr (struct "W")) (var (struct "W") "w"))))
      (block
        (expr (eh-construct 5))
        (return (var int "tmp1"))))))

(function "_ZNK1V1kEv"
  (returns int)
  (params (param "tmp2" (const (ptr (const (struct "V"))))))
  (block
    (return (const int 1))))

(function "_ZN1VD1Ev"
  (returns void)
  (params (param "tmp3" (const (ptr (struct "V")))))
  (block
    (expr (assign (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (struct "V")) "tmp3") (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1V") 16))))
    (return)))

(function "_ZN1VD0Ev"
  (returns void)
  (params (param "tmp4" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VD1Ev") (var (ptr (struct "V")) "tmp4")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "V")) "tmp4")) (const unsigned_long 8)))
    (return)))

(function "_ZN1VD2Ev"
  (returns void)
  (params (param "tmp5" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VD1Ev") (var (ptr (struct "V")) "tmp5")))
    (return)))

(function "_ZN1VC1Ev"
  (returns void)
  (params (param "tmp6" (const (ptr (struct "V")))))
  (block
    (expr (assign (ptr (const long)) (points_to_field (ptr (const long)) (var (ptr (struct "V")) "tmp6") (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1V") 16))))
    (return)))

(function "_ZN1VC2Ev"
  (returns void)
  (params (param "tmp7" (const (ptr (struct "V")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "V"))))) "_ZN1VC1Ev") (var (ptr (struct "V")) "tmp7")))
    (return)))

(function "_ZNK1W1kEv"
  (returns int)
  (params (param "tmp8" (const (ptr (const (struct "W"))))))
  (block
    (return (const int 2))))

(function "_ZN1WC1Ev"
  (returns void)
  (params (param "tmp9" (const (ptr (struct "W")))))
  (block
    (expr (eh-construct 4))
    (expr (call void (routine (ptr (fn void ((const (ptr (struct "V")))))) "_ZN1VC2Ev") (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp9") (field "__b_1V")))))
    (expr (eh-construct 2 0))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp9") (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1W") 16))))
    (block
      (expr (eh-construct 2 65535))
      (block
        (expr (eh-construct 5))
        (return)))))

(function "_ZN1WC2Ev"
  (returns void)
  (params (param "tmp10" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WC1Ev") (var (ptr (struct "W")) "tmp10")))
    (return)))

(function "_ZN1WD1Ev"
  (returns void)
  (params (param "tmp11" (const (ptr (struct "W")))))
  (block
    (expr (eh-construct 4))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp11") (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1W") 16))))
    (expr (eh-construct 2 0))
    (block
      (expr (eh-construct 2 65535)))
    (block
      (expr (eh-construct 2 65535))
      (expr (call void (routine (ptr (fn void ((const (ptr (struct "V")))))) "_ZN1VD2Ev") (address_of (ptr (struct "V")) (points_to_field (struct "V") (var (ptr (struct "W")) "tmp11") (field "__b_1V"))))))
    (block
      (expr (eh-construct 5))
      (return))))

(function "_ZN1WD0Ev"
  (returns void)
  (params (param "tmp12" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (var (ptr (struct "W")) "tmp12")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "W")) "tmp12")) (const unsigned_long 8)))
    (return)))

(function "_ZN1WD2Ev"
  (returns void)
  (params (param "tmp13" (const (ptr (struct "W")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "W"))))) "_ZN1WD1Ev") (var (ptr (struct "W")) "tmp13")))
    (return)))

(function "_ZNK1X1kEv"
  (returns int)
  (params (param "tmp14" (const (ptr (const (struct "X"))))))
  (block
    (return (const int 3))))

(function "_ZN1XC1Ev"
  (returns void)
  (params (param "tmp15" (const (ptr (struct "X")))))
  (block
    (expr (eh-construct 4))
    (expr (call void (routine (ptr (fn void ((const (ptr (struct "W")))))) "_ZN1WC2Ev") (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp15") (field "__b_1W")))))
    (expr (eh-construct 2 0))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (dot_field (struct "V") (points_to_field (struct "W") (var (ptr (struct "X")) "tmp15") (field "__b_1W")) (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1X") 16))))
    (block
      (expr (eh-construct 2 65535))
      (block
        (expr (eh-construct 5))
        (return)))))

(function "_ZN1XC2Ev"
  (returns void)
  (params (param "tmp16" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XC1Ev") (var (ptr (struct "X")) "tmp16")))
    (return)))

(function "_ZN1XD1Ev"
  (returns void)
  (params (param "tmp17" (const (ptr (struct "X")))))
  (block
    (expr (eh-construct 4))
    (expr (assign (ptr (const long)) (dot_field (ptr (const long)) (dot_field (struct "V") (points_to_field (struct "W") (var (ptr (struct "X")) "tmp17") (field "__b_1W")) (field "__b_1V")) (field "__vptr")) (const (ptr (const long)) (address (variable "_ZTV1X") 16))))
    (expr (eh-construct 2 0))
    (block
      (expr (eh-construct 2 65535)))
    (block
      (expr (eh-construct 2 65535))
      (expr (call void (routine (ptr (fn void ((const (ptr (struct "W")))))) "_ZN1WD2Ev") (address_of (ptr (struct "W")) (points_to_field (struct "W") (var (ptr (struct "X")) "tmp17") (field "__b_1W"))))))
    (block
      (expr (eh-construct 5))
      (return))))

(function "_ZN1XD0Ev"
  (returns void)
  (params (param "tmp18" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (var (ptr (struct "X")) "tmp18")))
    (expr (call void (routine (ptr (fn void ((ptr void) unsigned_long))) "_ZdlPvm") (cast (ptr void) (var (ptr (struct "X")) "tmp18")) (const unsigned_long 8)))
    (return)))

(function "_ZN1XD2Ev"
  (returns void)
  (params (param "tmp19" (const (ptr (struct "X")))))
  (block
    (expr (call void (routine (ptr (fn void ((ptr (struct "X"))))) "_ZN1XD1Ev") (var (ptr (struct "X")) "tmp19")))
    (return)))
