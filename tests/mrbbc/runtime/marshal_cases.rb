# the values of marshal_test.c, in the same order; prints each one's Marshal.dump as hex (CRuby's Marshal)
cases = [
  nil, true, false, 0, 1, 122, 123, -1, -123, -124, 300, -300,
  (1 << 30) - 1, 1 << 30, -(1 << 30), 1 << 40, -(1 << 40), 1 << 62,
  "", "hi", "héllo", :a, :abc,
  [1, "a"], [:a, :a], (x = "x"; [x, x]),
  {"k" => 2},
  {"topic_id" => 42, "tags" => ["ruby", "mruby"], "closed" => false, "note" => nil}
]
cases.each_with_index { |v, i| puts "#{i} #{Marshal.dump(v).unpack1('H*')}" }
