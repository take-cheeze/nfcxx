(translation-unit "constexpr_static.cpp")

(function "_Z4facti"
  (returns int)
  (params (param "n" int))
  (block
    (return (question int (le int (var int "n") (const int 1)) (const int 1) (multiply int (var int "n") (call int (routine (ptr (fn int (int))) "_Z4facti") (subtract int (var int "n") (const int 1))))))))

(function "main"
  (returns int)
  (params)
  (block
    (return (const int 120))))
