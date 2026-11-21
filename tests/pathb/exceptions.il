(translation-unit "exceptions.cpp")
(global "_ZTI1E" (const (struct "__class_type_info")))
(global "_ZTVN10__cxxabiv117__class_type_infoE" (const (array 0 (const long))))
(global "_ZTS1E" (const (array 3 (const char))))

(function "_Z7throweri"
  (returns int)
  (params (param "x" int))
  (block
    (if (gt int (var int "x") (const int 2))
      (block
        (expr (throw (struct "E") (assign int (points_to_field int (cast (ptr (struct "E")) (eh-construct 1)) (field "v")) (var int "x"))))))
    (return (var int "x"))))

(function "main"
  (returns int)
  (params)
  (block
    (local "tmp1" int)
    (expr (eh-construct 4))
    (try
      (block
        (block
          (block
            (expr (assign int (var int "tmp1") (add int (call int (routine (ptr (fn int (int))) "_Z7throweri") (const int 1)) (call int (routine (ptr (fn int (int))) "_Z7throweri") (const int 5)))))
            (expr (eh-construct 7))
            (block
              (expr (eh-construct 5))
              (return (var int "tmp1")))
            (expr (eh-construct 3 65535)))))
      (handler (ptr (struct "E"))
        (block
          (local "tmp2" int)
          (local "e" (ptr (struct "E")))
          (expr (eh-construct 2 0))
          (expr (assign (ptr (struct "E")) (var (ptr (struct "E")) "e") (cast (ptr (struct "E")) (eh-construct 0))))
          (expr (eh-construct 8))
          (block
            (expr (assign int (var int "tmp2") (add int (points_to_field int (var (ptr (struct "E")) "e") (field "v")) (const int 10))))
            (expr (eh-construct 2 65535))
            (expr (eh-construct 6))
            (expr (eh-construct 7))
            (block
              (expr (eh-construct 5))
              (return (var int "tmp2")))
            (expr (eh-construct 3 0)))
          (expr (eh-construct 3 65535)))))
    (expr (eh-construct 7))))
