(translation-unit "signed_overflow_wraps.cpp")

(function "_Z5wrapsi"
  (returns bool)
  (params (param "a" int))
  (block
    (return (cast bool (lt int (add int (var int "a") (const int 1)) (var int "a"))))))

(function "main"
  (returns int)
  (params)
  (block
    (return (question int (call bool (routine (ptr (fn bool (int))) "_Z5wrapsi") (const int 2147483647)) (const int 1) (const int 0)))))
