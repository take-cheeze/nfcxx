(translation-unit "exceptions.cpp")
(global "_ZTI1E" (const (struct "__class_type_info")))
(global "__curr_eh_stack_entry" (ptr (struct "__C7")))
(global "__eh_curr_region" unsigned_short)
(global "__caught_object_address" (ptr void))
(global "__catch_clause_number" int)
(global "_ZTVN10__cxxabiv117__class_type_infoE" (const (array 0 (const long))))
(global "_ZTS1E" (const (array 3 (const char))))

(function "_Z7throweri"
  (returns int)
  (params (param "x" int))
  (block
    (if (gt int (var int "x") (const int 2))
      (block
        (local "tmp1" (ptr (struct "E")))
        (expr (comma void (assign (ptr (struct "E")) (var (ptr (struct "E")) "tmp1") (cast (ptr (struct "E")) (call (ptr void) (routine (ptr (fn (ptr void) ((ptr (const void)) unsigned_long unsigned_int))) "__throw_setup") (cast (ptr (const void)) (address_of (ptr (const (struct "__class_type_info"))) (var (const (struct "__class_type_info")) "_ZTI1E"))) (const unsigned_long 4) (const unsigned_int 0)))) (comma void (assign int (points_to_field int (var (ptr (struct "E")) "tmp1") (field "v")) (var int "x")) (call void (routine (ptr (fn void ())) "__throw")))))))
    (return (var int "x"))))

(function "main"
  (returns int)
  (params)
  (block
    (local "tmp2" (struct "__C7"))
    (local "tmp3" int)
    (local "tmp4" (struct "__C7"))
    (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp4") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
    (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp4"))))
    (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp4") (field "kind")) (const unsigned_char 1)))
    (expr (assign (ptr (struct "__C2")) (dot_field (ptr (struct "__C2")) (dot_field (struct "__C3") (dot_field (union "__C6") (var (struct "__C7") "tmp4") (field "variant")) (field "function")) (field "regions")) (array_to_pointer (ptr (struct "__C2")) (var (array 1 (struct "__C2")) "tmp5"))))
    (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C6") (var (struct "__C7") "tmp4") (field "variant")) (field "function")) (field "saved_region_number")) (var unsigned_short "__eh_curr_region")))
    (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
    (block
      (expr (assign (ptr (struct "__C7")) (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp2") (field "next")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry")))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (address_of (ptr (struct "__C7")) (var (struct "__C7") "tmp2"))))
      (expr (assign unsigned_char (dot_field unsigned_char (var (struct "__C7") "tmp2") (field "kind")) (const unsigned_char 5)))
      (expr (assign (ptr (struct "__C4")) (dot_field (ptr (struct "__C4")) (dot_field (struct "__C5") (dot_field (union "__C6") (var (struct "__C7") "tmp2") (field "variant")) (field "try_block")) (field "catch_entries")) (array_to_pointer (ptr (struct "__C4")) (var (array 1 (struct "__C4")) "tmp6"))))
      (expr (assign (ptr void) (dot_field (ptr void) (dot_field (struct "__C5") (dot_field (union "__C6") (var (struct "__C7") "tmp2") (field "variant")) (field "try_block")) (field "rtinfo")) (const (ptr void) 0)))
      (expr (assign unsigned_short (dot_field unsigned_short (dot_field (struct "__C5") (dot_field (union "__C6") (var (struct "__C7") "tmp2") (field "variant")) (field "try_block")) (field "region_number")) (var unsigned_short "__eh_curr_region")))
      (if (eq int (call int (routine (ptr (fn int ((array 25 long)))) "_setjmp") (array_to_pointer (ptr long) (dot_field (array 25 long) (dot_field (struct "__C5") (dot_field (union "__C6") (var (struct "__C7") "tmp2") (field "variant")) (field "try_block")) (field "setjmp_buffer")))) (const int 0))
        (block
          (block
            (expr (assign int (var int "tmp3") (add int (call int (routine (ptr (fn int (int))) "_Z7throweri") (const int 1)) (call int (routine (ptr (fn int (int))) "_Z7throweri") (const int 5)))))
            (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp2") (field "next"))))
            (block
              (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C6") (var (struct "__C7") "tmp4") (field "variant")) (field "function")) (field "saved_region_number"))))
              (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp4") (field "next"))))
              (return (var int "tmp3")))))
        (if (eq int (var int "__catch_clause_number") (const int 1))
          (block
            (local "tmp7" int)
            (local "e" (ptr (struct "E")))
            (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 0)))
            (expr (assign (ptr (struct "E")) (var (ptr (struct "E")) "e") (cast (ptr (struct "E")) (var (ptr void) "__caught_object_address"))))
            (expr (call void (routine (ptr (fn void ())) "__exception_caught")))
            (block
              (expr (assign int (var int "tmp7") (add int (points_to_field int (var (ptr (struct "E")) "e") (field "v")) (const int 10))))
              (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (const unsigned_short 65535)))
              (expr (call void (routine (ptr (fn void ())) "__destroy_exception_object")))
              (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp2") (field "next"))))
              (block
                (expr (assign unsigned_short (var unsigned_short "__eh_curr_region") (dot_field unsigned_short (dot_field (struct "__C3") (dot_field (union "__C6") (var (struct "__C7") "tmp4") (field "variant")) (field "function")) (field "saved_region_number"))))
                (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp4") (field "next"))))
                (return (var int "tmp7")))))))
      (expr (assign (ptr (struct "__C7")) (var (ptr (struct "__C7")) "__curr_eh_stack_entry") (dot_field (ptr (struct "__C7")) (var (struct "__C7") "tmp2") (field "next")))))))
