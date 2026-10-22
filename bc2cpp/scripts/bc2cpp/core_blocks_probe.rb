# Fiber, external-enumeration and block-control probes for the compiled core.
#
# Run by scripts/bc2cpp/core_mrbtest.rb under the interpreted and the compiled full-core
# mruby; the two outputs must be identical. Every line is `name: result` with the class and
# message of an exception in place of the result, so it needs only what mruby has: no
# CRuby-only API. Method#arity and an ArgumentError raised for keywords are left out on
# purpose (a compiled method is a C function to reflection, and its registered aspec makes
# the VM count a keyword hash where OP_ENTER did not).
$out = []
def t(name)
  r = begin
    yield.inspect
  rescue Exception => e
    "#{e.class}: #{e.message}"
  end
  puts "#{name}: #{r}"
end

class Bag
  include Enumerable
  def initialize(*a); @a = a; end
  def each
    return to_enum(:each) unless block_given?
    @a.each { |x| yield x }
    self
  end
end

class Multi
  include Enumerable
  def each
    yield 1, 2
    yield 3
    yield [4, 5]
    yield
  end
end

class Stops
  include Enumerable
  def each(&b)
    $stored = b
    b.call(1)
    b.call(2)
  end
end

A = [3, 1, 4, 1, 5, 9, 2, 6]
H = { a: 1, b: 2, c: 3 }
R = (1..6)
B = Bag.new(5, 3, 8, 1)
M = Multi.new

# ---- Array
t('a.each') { r = []; A.each { |x| r << x * 2 }; r }
t('a.each ret') { A.each { |x| x }.equal?(A) }
t('a.each no block') { e = A.each; [e.class, e.size, e.next, e.next] }
t('a.each break') { A.each { |x| break x * 10 if x == 4 } }
t('a.each next') { r = []; A.each { |x| next if x.odd?; r << x }; r }
def ret_from_each(a); a.each { |x| return x * 100 if x > 3 }; :none; end
t('return through each') { [ret_from_each(A), ret_from_each([1])] }
t('a.each raise') { A.each { |x| raise ArgumentError, "boom #{x}" if x == 4 } }
t('a.each ensure') { r = []; begin; A.each { |x| raise 'x' if x == 4; r << x }; rescue => e; r << e.message; ensure; r << :ens; end; r }
t('a.each_index') { r = []; A.each_index { |i| r << i }; r }
t('a.each_index none') { A.each_index.to_a }
t('a.each arg') { A.each(1) { } }
t('a.each_with_index') { r = []; A.each_with_index { |x, i| r << [x, i] }; r }
t('a.each_with_index none') { A.each_with_index.to_a }
t('a.each_with_index arr') { r = []; A.each_with_index { |*a| r << a }; r }
t('a.map') { A.map { |x| x + 1 } }
t('a.map none') { A.map.class }
t('a.collect!') { a = A.dup; a.collect! { |x| x * 2 }; a }
t('a.map!') { a = A.dup; a.map! { |x| x * 2 } }
t('a.select') { A.select { |x| x > 3 } }
t('a.select!') { a = A.dup; [a.select! { |x| x > 3 }, a] }
t('a.select! none') { a = A.dup; [a.select! { |x| true }, a] }
t('a.reject') { A.reject { |x| x > 3 } }
t('a.reject!') { a = A.dup; [a.reject! { |x| x > 3 }, a] }
t('a.reject! none') { a = A.dup; a.reject! { |x| false } }
t('a.delete_if') { a = A.dup; [a.delete_if { |x| x > 3 }, a] }
t('a.keep_if') { a = A.dup; [a.keep_if { |x| x > 3 }, a] }
t('a.reverse_each') { r = []; A.reverse_each { |x| r << x }; r }
t('a.uniq') { A.uniq }
t('a.uniq blk') { A.uniq { |x| x % 3 } }
t('a.uniq!') { a = A.dup; [a.uniq!, a] }
t('a.uniq! none') { a = [1, 2]; a.uniq! }
t('a.bsearch') { [1, 3, 5, 7].bsearch { |x| x >= 4 } }
t('a.bsearch_index') { [1, 3, 5, 7].bsearch_index { |x| x >= 4 } }
t('a.sort') { A.sort }
t('a.sort blk') { A.sort { |a, b| b <=> a } }
t('a.sort fail') { [1, 'a'].sort }
t('a.sort_by') { A.sort_by { |x| -x } }
t('a.sort_by!') { a = A.dup; a.sort_by! { |x| -x }; a }
t('a.min') { [A.min, A.max, A.min { |a, b| b <=> a }, A.minmax] }
t('a.min n') { [A.min(2), A.max(2)] }
t('a.min_by') { [A.min_by { |x| -x }, A.max_by { |x| -x }, A.minmax_by { |x| x % 4 }] }
t('a.inject') { [A.inject(:+), A.inject(10, :+), A.inject { |a, b| a * b }, A.inject(2) { |a, b| a + b }] }
t('a.inject empty') { [[].inject(:+), [].inject(1) { |a, b| a }] }
t('a.sum') { [A.sum, A.sum(0.0), A.sum { |x| x * 2 }, [0.1, 0.2, 0.3].sum, [].sum] }
t('a.count') { [A.count, A.count(1), A.count { |x| x > 3 }] }
t('a.find') { [A.find { |x| x > 4 }, A.find { |x| x > 100 }, A.detect(-> { :none }) { |x| x > 100 }] }
t('a.find_index') { [A.find_index(4), A.find_index { |x| x > 4 }, A.find_index(99)] }
t('a.any?') { [A.any?, A.any? { |x| x > 8 }, A.any?(Integer), [].any?, [nil].any?, A.any?(100)] }
t('a.all?') { [A.all?, A.all? { |x| x > 0 }, A.all?(Integer), [].all?, [nil].all?] }
t('a.none?') { [A.none?, A.none? { |x| x > 100 }, A.none?(String), [nil].none?] }
t('a.one?') { [A.one?, A.one? { |x| x == 9 }, A.one?(9), [1].one?] }
t('a.flat_map') { A.flat_map { |x| [x, x] } }
t('a.zip') { [A.zip(A), [1, 2].zip([3], [4, 5, 6]), A.zip([1]) { |x| x }] }
t('a.each_slice') { r = []; A.each_slice(3) { |s| r << s }; r }
t('a.each_slice none') { A.each_slice(3).to_a }
t('a.each_cons') { r = []; A.each_cons(3) { |s| r << s }; r }
t('a.each_slice 0') { A.each_slice(0) { } }
t('a.each_with_object') { A.each_with_object([]) { |x, m| m << x } }
t('a.group_by') { A.group_by { |x| x % 3 } }
t('a.partition') { A.partition { |x| x > 3 } }
t('a.take_while') { A.take_while { |x| x < 5 } }
t('a.drop_while') { A.drop_while { |x| x < 5 } }
t('a.take') { [A.take(2), A.drop(6)] }
t('a.tally') { A.tally }
t('a.filter_map') { A.filter_map { |x| x * 2 if x.odd? } }
t('a.cycle') { r = []; A.cycle(2) { |x| r << x }; r }
t('a.first') { [A.first, A.first(3), [].first, [].first(2)] }
t('a.include?') { [A.include?(4), A.include?(99)] }
t('a.entries') { A.entries }
t('a.to_h') { [[1, 2], [3, 4]].to_h }
t('a.to_h blk') { [1, 2].to_h { |x| [x, x * 2] } }
t('a.to_h bad') { [1].to_h }
t('a.grep') { [A.grep(2..4), A.grep(2..4) { |x| x * 2 }, A.grep_v(2..4)] }
t('a.permutation') { r = []; [1, 2, 3].permutation(2) { |x| r << x }; r }
t('a.combination') { r = []; [1, 2, 3].combination(2) { |x| r << x }; r }
t('a.product') { [1, 2].product([3, 4]) }
t('a.fetch') { [A.fetch(1), A.fetch(100, :d), A.fetch(100) { |i| i * 2 }] }
t('a.fetch err') { A.fetch(100) }
t('a.fill') { [[1, 2, 3].fill(0), [1, 2, 3].fill { |i| i * i }, [1, 2, 3].fill(9, 1), [1, 2, 3].fill(1, 1) { |i| i }] }
t('a.transpose') { [[1, 2], [3, 4]].transpose }
t('a.each_entry') { r = []; Bag.new(1, 2).each_entry { |x| r << x }; r }
t('a.step') { r = []; 1.step(10, 3) { |x| r << x }; r }
t('a.chunk') { A.each_slice(2).map(&:sum) }

# ---- Hash
t('h.each') { r = []; H.each { |k, v| r << [k, v] }; r }
t('h.each pair') { r = []; H.each { |kv| r << kv }; r }
t('h.each none') { e = H.each; [e.class, e.next] }
t('h.each break') { H.each { |k, v| break k if v == 2 } }
t('h.each_key') { r = []; H.each_key { |k| r << k }; r }
t('h.each_value') { r = []; H.each_value { |v| r << v }; r }
t('h.map') { H.map { |k, v| [k, v * 2] } }
t('h.select') { H.select { |k, v| v > 1 } }
t('h.reject') { H.reject { |k, v| v > 1 } }
t('h.select!') { h = H.dup; [h.select! { |k, v| v > 1 }, h] }
t('h.reject!') { h = H.dup; [h.reject! { |k, v| v > 1 }, h] }
t('h.delete_if') { h = H.dup; [h.delete_if { |k, v| v > 1 }, h] }
t('h.keep_if') { h = H.dup; [h.keep_if { |k, v| v > 1 }, h] }
t('h.any?') { [H.any?, H.any? { |k, v| v > 2 }, {}.any?] }
t('h.count') { [H.count, H.count { |k, v| v > 1 }] }
t('h.merge') { [H.merge({ d: 4 }), H.merge({ a: 5 }) { |k, a, b| a + b }] }
t('h.merge!') { h = H.dup; h.merge!({ a: 5 }) { |k, a, b| a + b }; h }
t('h.transform_values') { [H.transform_values { |v| v * 2 }, H.transform_values.class] }
t('h.transform_values!') { h = H.dup; h.transform_values! { |v| v * 2 }; h }
t('h.transform_keys') { [H.transform_keys { |k| k.to_s }, H.transform_keys({ a: :z })] }
t('h.transform_keys!') { h = H.dup; h.transform_keys! { |k| k.to_s }; h }
t('h.fetch') { [H.fetch(:a), H.fetch(:z, 0), H.fetch(:z) { |k| k }] }
t('h.fetch err') { H.fetch(:z) }
t('h.invert') { H.invert }
t('h.fetch_values') { [H.fetch_values(:a, :b), H.fetch_values(:z) { |k| k }] }
t('h.sort_by') { H.sort_by { |k, v| -v } }
t('h.min_by') { H.min_by { |k, v| -v } }
t('h.inject') { H.inject(0) { |s, (k, v)| s + v } }
t('h.sum') { H.sum { |k, v| v } }
t('h.to_a') { H.to_a }
t('h.find') { H.find { |k, v| v == 2 } }
t('h.each_with_index') { r = []; H.each_with_index { |(k, v), i| r << [k, v, i] }; r }
t('h.group_by') { H.group_by { |k, v| v.odd? } }
t('h.partition') { H.partition { |k, v| v > 1 } }
t('h.flat_map') { H.flat_map { |k, v| [k] * v } }
t('h.zip') { H.zip([1, 2, 3]) }
t('h.each_slice') { H.each_slice(2).to_a }
t('h.dig') { { a: { b: [1, 2] } }.dig(:a, :b, 1) }
t('h.first') { [H.first, H.first(2)] }
t('h.min') { [H.min, H.max] }
t('h.uniq') { H.uniq { |k, v| v % 2 } }
t('h.sort') { H.sort }
t('h.count arg') { H.count([:a, 1]) }
t('h.compact') { { a: nil, b: 1 }.compact }
t('h.flatten') { { a: [1, 2] }.flatten(2) }

# ---- Range
t('r.each') { r = []; R.each { |x| r << x }; r }
t('r.each none') { e = R.each; [e.class, e.next, e.next] }
t('r.each break') { R.each { |x| break x if x == 3 } }
t('r.each str') { r = []; ('a'..'e').each { |x| r << x }; r }
t('r.each float') { (1.0..2.0).each { } }
t('r.each endless') { r = []; (1..).each { |x| r << x; break if x > 3 }; r }
t('r.each excl') { r = []; (1...4).each { |x| r << x }; r }
t('r.map') { R.map { |x| x * x } }
t('r.select') { R.select(&:even?) }
t('r.reject') { R.reject(&:even?) }
t('r.step') { r = []; R.step(2) { |x| r << x }; r }
t('r.step none') { R.step(2).to_a }
t('r.sum') { [R.sum, R.sum { |x| x * 2 }, (1..0).sum] }
t('r.min') { [R.min, R.max, R.min { |a, b| b <=> a }, (1..0).min, (1...1).max] }
t('r.to_a') { [R.to_a, (1..).first(2), ('a'..'c').to_a] }
t('r.include') { [R.include?(3), R.include?(9), R === 3] }
t('r.inject') { R.inject(:+) }
t('r.each_slice') { R.each_slice(4).to_a }
t('r.each_with_index') { r = []; R.each_with_index { |x, i| r << x * i }; r }
t('r.count') { [R.count, R.count(&:even?)] }
t('r.first') { [R.first, R.first(3), R.last, R.last(2)] }
t('r.find') { R.find { |x| x > 3 } }
t('r.all?') { [R.all? { |x| x > 0 }, R.any? { |x| x > 5 }, R.none? { |x| x > 6 }] }
t('r.zip') { R.zip(R) }
t('r.reverse_each') { r = []; R.reverse_each { |x| r << x }; r }
t('r.flat_map') { (1..3).flat_map { |x| [x] * x } }
t('r.group_by') { R.group_by { |x| x % 3 } }
t('r.partition') { R.partition(&:odd?) }
t('r.entries') { (1..3).entries }
t('r.to_h') { (1..3).to_h { |x| [x, x] } }
t('r.hash') { (1..3).hash == (1..3).hash }
t('r.min_by') { R.min_by { |x| -x } }
t('r.sort_by') { R.sort_by { |x| -x } }
t('r.tally') { R.tally }
t('r.each_cons') { R.each_cons(5).to_a }
t('r.step float') { r = []; 1.0.step(2.0, 0.5) { |x| r << x }; r }

# ---- Integer / Float / Kernel / String
t('int.times') { r = []; 4.times { |i| r << i }; r }
t('int.times none') { e = 3.times; [e.class, e.size, e.to_a] }
t('int.times break') { 10.times { |i| break i if i == 3 } }
t('int.times ret') { 5.times { } }
t('int.times neg') { -1.times { raise 'no' } }
t('int.upto') { r = []; 1.upto(4) { |i| r << i }; r }
t('int.upto none') { 1.upto(3).to_a }
t('int.downto') { r = []; 4.downto(1) { |i| r << i }; r }
t('int.downto none') { 3.downto(1).to_a }
t('int.upto bad') { 1.upto('a') { } }
t('int.upto float') { r = []; 1.upto(3.5) { |i| r << i }; r }
t('int.step') { r = []; 1.step(10, 4) { |i| r << i }; r }
t('int.step neg') { r = []; 10.step(1, -4) { |i| r << i }; r }
t('int.step zero') { 1.step(10, 0) { break } }
t('int.step none') { 1.step(10, 4).to_a }
t('flt.step') { r = []; 1.0.step(2.0, 0.5) { |x| r << x }; r }
t('loop') { i = 0; loop { i += 1; break i if i > 3 } }
t('loop stop') { e = [1, 2].each; r = []; loop { r << e.next }; r }
t('loop ret') { loop { raise StopIteration } }
t('loop none') { loop.class }
t('str.each_char') { r = []; 'abc'.each_char { |c| r << c }; r }
t('str.each_char none') { 'abc'.each_char.to_a }
t('str.each_line') { r = []; "a\nb\nc".each_line { |l| r << l }; r }
t('str.each_line sep') { r = []; "a,b,c".each_line(',') { |l| r << l }; r }
t('str.each_byte') { r = []; 'ab'.each_byte { |b| r << b }; r }
t('str.chars') { ['abc'.chars, 'abc'.bytes, "a\nb".lines, 'ab'.codepoints] }
t('str.upto') { r = []; 'a'.upto('e') { |x| r << x }; r }
t('str.upto excl') { r = []; 'a'.upto('e', true) { |x| r << x }; r }
t('str.gsub') { ['hello'.gsub('l') { |m| m.upcase }, 'hello'.gsub('l', 'L'), 'hello'.gsub('l', 'l' => '1')] }
t('str.sub') { ['hello'.sub('l') { |m| m.upcase }, 'hello'.sub('l', 'L')] }
t('str.gsub!') { s = 'hello'; [s.gsub!('l') { 'L' }, s] }
t('str.sub!') { s = 'hello'; [s.sub!('l') { 'L' }, s] }
t('str.gsub none') { 'hello'.gsub('l').class }
t('str.%') { ['%d-%s' % [1, 'a'], '%05.1f' % 3.14159] }
t('kernel.`') { `echo hi` }
t('sym.to_proc') { [%w[a b].map(&:upcase), [1, 2].map(&:to_s), :upcase.to_proc.call('x')] }
t('sym.to_proc arity') { [:upcase.to_proc.arity, :upcase.to_proc.lambda?] }
t('hash.to_proc') { [[:a, :b].map(&H), H.to_proc.call(:a)] }
t('method.to_proc') { [1, 2].map(&10.method(:+)) }

# ---- Struct
S = Struct.new(:a, :b)
t('struct.each') { r = []; S.new(1, 2).each { |x| r << x }; r }
t('struct.each_pair') { r = []; S.new(1, 2).each_pair { |k, v| r << [k, v] }; r }
t('struct.select') { S.new(1, 2).select { |x| x > 1 } }
t('struct.map') { S.new(1, 2).map { |x| x * 2 } }
t('struct.dig') { S.new({ a: [7] }, 2).dig(:a, :a, 0) }
t('struct.to_a') { S.new(1, 2).to_a }
t('struct.each none') { S.new(1, 2).each.to_a }

# ---- custom Enumerable
t('bag.map') { B.map { |x| x * 2 } }
t('bag.select') { B.select { |x| x > 2 } }
t('bag.sort') { B.sort }
t('bag.min') { [B.min, B.max, B.minmax, B.min(2)] }
t('bag.sum') { B.sum }
t('bag.inject') { [B.inject(:+), B.inject { |a, b| a * b }] }
t('bag.first') { [B.first, B.first(2)] }
t('bag.to_a') { [B.to_a, B.entries, B.include?(3)] }
t('bag.count') { [B.count, B.count(3), B.count { |x| x > 2 }] }
t('bag.each_slice') { B.each_slice(2).to_a }
t('bag.each_with_index') { B.each_with_index.to_a }
t('bag.zip') { B.zip(B) }
t('bag.sort_by') { B.sort_by { |x| -x } }
t('bag.min_by') { B.min_by { |x| -x } }
t('bag.group_by') { B.group_by(&:odd?) }
t('bag.reduce break') { B.each { |x| break x if x == 8 } }
t('bag.lazy') { B.lazy.map { |x| x * 2 }.first(2) }
t('bag.each_entry') { r = []; B.each_entry { |x| r << x }; r }
t('bag.take_while') { B.take_while { |x| x > 2 } }
t('bag.all?') { [B.all? { |x| x > 0 }, B.any?(8), B.none?, B.one? { |x| x == 8 }] }
t('bag.uniq') { B.uniq }
t('bag.to_set') { B.to_set.size }
t('multi.to_a') { M.to_a }
t('multi.map') { M.map { |x| x } }
t('multi.map2') { M.map { |x, y| [x, y] } }
t('multi.each_slice') { M.each_slice(2).to_a }
t('multi.each_with_index') { M.each_with_index.to_a }
t('multi.first') { M.first(3) }
t('multi.select') { M.select { |x| x } }
t('multi.sort_by') { M.sort_by { |x| x.to_s } }
t('multi.inject') { M.inject([]) { |a, x| a << x } }
t('multi.count') { M.count }
t('multi.group_by') { M.group_by { |x| x.class } }
t('multi.min_by') { M.min_by { |x| x.to_s } }
t('multi.zip') { M.zip(M) }
t('multi.include?') { M.include?([1, 2]) }
t('multi.entries') { M.entries }
t('multi.each_entry') { r = []; M.each_entry { |x| r << x }; r }
t('stops.map') { Stops.new.map { |x| x * 2 } }
t('stops.stored') { Stops.new.to_a; $stored.class }
t('stops.select') { Stops.new.select { |x| x > 1 } }

# ---- Fibers and external enumeration (the compiled iterators must yield to the VM)
t('fiber each') do
  f = Fiber.new { A.each { |x| Fiber.yield x }; :done }
  Array.new(A.size + 1) { f.resume }
end
t('fiber times') do
  f = Fiber.new { 3.times { |i| Fiber.yield i }; :done }
  Array.new(4) { f.resume }
end
t('fiber map') do
  f = Fiber.new { A.map { |x| Fiber.yield x; x * 2 } }
  Array.new(A.size + 1) { f.resume }
end
t('fiber hash') do
  f = Fiber.new { H.each { |k, v| Fiber.yield [k, v] }; :done }
  Array.new(4) { f.resume }
end
t('fiber range') do
  f = Fiber.new { R.each { |x| Fiber.yield x }; :done }
  Array.new(7) { f.resume }
end
t('fiber loop') do
  f = Fiber.new { i = 0; loop { Fiber.yield i; i += 1; break if i > 2 }; :done }
  Array.new(4) { f.resume }
end
t('fiber enumerable') do
  f = Fiber.new { B.each { |x| Fiber.yield x }; B.map { |x| Fiber.yield(x); x }; :done }
  Array.new(9) { f.resume }
end
t('fiber upto') do
  f = Fiber.new { 1.upto(3) { |i| Fiber.yield i }; 3.downto(1) { |i| Fiber.yield i }; :done }
  Array.new(7) { f.resume }
end
t('fiber inject') do
  f = Fiber.new { A.inject(0) { |s, x| Fiber.yield s; s + x } }
  Array.new(A.size + 1) { f.resume }
end
t('fiber select') do
  f = Fiber.new { A.select { |x| Fiber.yield x; x > 3 } }
  Array.new(A.size + 1) { f.resume }
end
t('fiber sort_by') do
  f = Fiber.new { A.sort_by { |x| Fiber.yield x; -x } }
  Array.new(A.size + 1) { f.resume }
end
t('fiber each_slice') do
  f = Fiber.new { A.each_slice(3) { |s| Fiber.yield s }; :done }
  Array.new(4) { f.resume }
end
t('fiber each_with_index') do
  f = Fiber.new { A.each_with_index { |x, i| Fiber.yield [x, i] }; :done }
  Array.new(A.size + 1) { f.resume }
end
t('fiber nested') do
  outer = Fiber.new do
    [1, 2].each do |i|
      inner = Fiber.new { [10, 20].each { |j| Fiber.yield i * j }; :in_done }
      3.times { Fiber.yield inner.resume }
    end
    :out_done
  end
  Array.new(6) { outer.resume }
end
t('fiber resume in block') do
  r = []
  A.first(3).each do |x|
    f = Fiber.new { [x, x * 2].each { |y| Fiber.yield y }; :done }
    3.times { r << f.resume }
  end
  r
end
t('fiber transfer-free nested each') do
  f = Fiber.new do
    [[1, 2], [3, 4]].each { |row| row.each { |c| Fiber.yield c } }
    :done
  end
  Array.new(5) { f.resume }
end
t('fiber raise') do
  f = Fiber.new { A.each { |x| raise 'in fiber' if x == 4; Fiber.yield x } }
  r = []
  begin; 5.times { r << f.resume }; rescue => e; r << e.message; end
  r
end
t('fiber break') do
  f = Fiber.new { r = A.each { |x| Fiber.yield x; break :broke if x == 4 }; r }
  Array.new(4) { f.resume }
end
t('fiber ensure') do
  log = []
  f = Fiber.new do
    begin
      A.each { |x| Fiber.yield x }
    ensure
      log << :ensure
    end
  end
  9.times { f.resume rescue log << :dead }
  log
end
t('root yield') { A.each { |x| Fiber.yield x } }
t('root yield times') { 3.times { |i| Fiber.yield i } }
t('enum next each') { e = A.each; Array.new(A.size) { e.next } }
t('enum next end') { e = [1].each; e.next; begin; e.next; rescue StopIteration => x; x.class; end }
t('enum peek rewind') { e = A.each; [e.next, e.peek, e.next, e.rewind.next] }
t('enum next map') { e = A.map; [e.next, e.next] }
t('enum next select') { e = A.select; [e.next, e.next] }
t('enum next ewi') { e = A.each_with_index; [e.next, e.next] }
t('enum next hash') { e = H.each; [e.next, e.next, e.next] }
t('enum next range') { e = R.each; [e.next, e.next] }
t('enum next times') { e = 3.times; [e.next, e.next, e.next] }
t('enum next upto') { e = 1.upto(3); [e.next, e.next, e.next] }
t('enum next bag') { e = B.each; [e.next, e.next] }
t('enum next multi') { e = M.each; [e.next, e.next, e.next, e.next] }
t('enum next each_slice') { e = A.each_slice(3); [e.next, e.next] }
t('enum next each_char') { e = 'abc'.each_char; [e.next, e.next, e.next] }
t('enum next string chars') { e = 'ab'.each_char; e.next; e.next; begin; e.next; rescue StopIteration; :stop; end }
t('enum with_index') { A.each.with_index(1).to_a }
t('enum with_object') { A.each.with_object([]).to_a.size }
t('enum map.with_index') { A.map.with_index { |x, i| x * i } }
t('enum select.with_index') { A.select.with_index { |x, i| i.even? } }
t('enum each_with_index.map') { A.each_with_index.map { |x, i| x + i } }
t('enum size') { [A.each.size, A.map.size, R.each.size, 3.times.size, H.each.size] }
t('enum new') { Enumerator.new { |y| A.each { |x| y << x } }.first(3) }
t('enum new next') { e = Enumerator.new { |y| A.each { |x| y << x * 2 } }; [e.next, e.next, e.next] }
t('enum new inf') { e = Enumerator.new { |y| i = 0; loop { y << i; i += 1 } }; [e.next, e.next, e.take(3)] }
t('enum new times') { e = Enumerator.new { |y| 3.times { |i| y.yield i, i * 2 } }; e.to_a }
t('enum lazy') { (1..Float::INFINITY).lazy.map { |x| x * 2 }.select { |x| x % 3 == 0 }.first(3) }
t('enum lazy arr') { A.lazy.map { |x| x + 1 }.to_a }
t('enum zip next') { e1 = A.each; e2 = R.each; [e1.next, e2.next, e1.next, e2.next] }
t('enum chain') { A.each.next }
t('enum external nested') do
  e = A.each_slice(2)
  f = e.next
  g = f.each
  [f, g.next, g.next]
end
t('enum next in fiber') do
  f = Fiber.new do
    e = A.each
    3.times { Fiber.yield e.next }
    :done
  end
  Array.new(4) { f.resume }
end
t('enum next in each') do
  e = R.each
  r = []
  A.each { |x| r << [x, e.next] }
  r
end
t('gen fiber map') do
  f = Fiber.new { Enumerator.new { |y| A.map { |x| y << x } }.each { |x| Fiber.yield x }; :done }
  Array.new(A.size + 1) { f.resume }
end

# ---- misc semantic edges
t('block_given') { def bg; block_given?; end; [bg, bg { }, bg(&nil)] }
t('respond') { [A.respond_to?(:each), A.respond_to?(:each_slice), Array.method_defined?(:uniq)] }
t('instance_methods') { Array.instance_methods(false).sort.first(3) }
t('proc block arg') { pr = proc { |x| x * 3 }; [A.map(&pr), A.each(&pr).size] }
t('lambda block arg') { l = ->(x) { x * 3 }; A.map(&l) }
t('lambda arity err') { l = ->(x, y) { x }; A.each(&l) }
t('method block arg') { [1, 2].each(&method(:puts)) }
t('block args destructure') { [[1, [2, 3]]].each { |a, (b, c)| p [a, b, c] } }
t('block args splat') { [[1, 2, 3]].each { |a, *b| p [a, b] } }
t('block args opt') { [[1]].each { |a, b = 5| p [a, b] } }
t('nested break') { A.each { |x| [1, 2].each { |y| break }; break :outer } }
t('nested ret') { def nr; [1].each { |x| [2].each { |y| return [x, y] } }; :no; end; nr }
t('redo-free next value') { A.map { |x| next 0 if x.odd?; x } }
t('each mutation') { a = [1, 2, 3]; r = []; a.each { |x| r << x; a << 9 if a.size < 5 }; r }
t('each delete') { a = [1, 2, 3, 4]; r = []; a.each { |x| r << x; a.delete(x) }; [r, a] }
t('map frozen') { [1].freeze.map { |x| x } }
t('select! frozen') { [1].freeze.select! { |x| x } }
t('uniq! frozen') { [1, 1].freeze.uniq! }
t('collect! frozen') { [1].freeze.collect! { |x| x } }
t('reject! frozen') { [1].freeze.reject! { |x| x } }
t('sort_by! frozen') { [1].freeze.sort_by! { |x| x } }
t('hash frozen') { { a: 1 }.freeze.select! { true } }
t('hash mut') { h = { a: 1 }; h.each { |k, v| h[:b] = 2 } }
t('gc stress') { r = 0; 2000.times { |i| r += [i, i + 1].map { |x| x.to_s }.size }; r }
t('deep recursion') { def deep(n); n.zero? ? 0 : [n].map { |x| deep(x - 1) }.first + 1; end; deep(100) }
t('deep recursion blow') { def deep2(n); [n].each { |x| deep2(x + 1) }; end; deep2(0) rescue $!.class }
t('exception in map') { A.map { |x| Integer('z') } }
t('nil block each') { A.each(&nil) }
t('nil block map') { A.map(&nil).class }
t('sym proc each') { A.each(&:to_s).equal?(A) }
t('each_with_index args') { A.each_with_index(1) { } }
t('to_enum') { A.to_enum(:each_slice, 2).to_a }
t('enum_for size') { A.enum_for(:each).size }


class Bag2
  include Enumerable
  def initialize(*a); @a = a; end
  def each; @a.each { |x| yield x }; self; end
end

BIG2 = (1..20000).to_a
BAG2 = Bag2.new(*(1..300).to_a)
HB2 = BIG2.first(3000).each_with_object({}) { |i, h| h[i] = i.to_s }

# arena / GC pressure: every iteration allocates
t('big each alloc') { n = 0; BIG2.each { |x| n += [x, x.to_s].size }; n }
t('big map str') { BIG2.map { |x| x.to_s }.size }
t('big map arr') { BIG2.map { |x| [x, [x]] }.size }
t('big select') { BIG2.select { |x| x.to_s.size > 3 }.size }
t('big reject') { BIG2.reject { |x| x.to_s.size > 3 }.size }
t('big inject') { BIG2.inject(0) { |s, x| s + x.to_s.size } }
t('big sum') { BIG2.sum { |x| x.to_s.size } }
t('big sort_by') { BIG2.sort_by { |x| -x.to_s.size * 100000 - x }.first(2) }
t('big sort') { BIG2.sort { |a, b| b <=> a }.first(2) }
t('big min_by') { BIG2.min_by { |x| x.to_s } }
t('big group_by') { BIG2.group_by { |x| x % 7 }.size }
t('big flat_map') { BIG2.flat_map { |x| [x.to_s] }.size }
t('big each_slice') { n = 0; BIG2.each_slice(7) { |s| n += s.size }; n }
t('big each_cons') { n = 0; BIG2.first(3000).each_cons(3) { |s| n += s.size }; n }
t('big zip') { BIG2.zip(BIG2).size }
t('big uniq') { BIG2.uniq { |x| x % 100 }.size }
t('big times') { n = 0; 20000.times { |i| n += i.to_s.size }; n }
t('big upto') { n = 0; 1.upto(20000) { |i| n += [i].size }; n }
t('big hash each') { n = 0; HB2.each { |k, v| n += v.size }; n }
t('big hash map') { HB2.map { |k, v| [k, v] }.size }
t('big hash select') { HB2.select { |k, v| v.size > 3 }.size }
t('big range each') { n = 0; (1..20000).each { |i| n += i.to_s.size }; n }
t('big range map') { (1..20000).map { |i| i.to_s }.size }
t('big bag map') { BAG2.map { |x| x.to_s }.size }
t('big str each_char') { n = 0; ('abc' * 5000).each_char { |c| n += c.size }; n }
t('big gsub') { ('abc' * 3000).gsub('b') { |m| m.upcase }.size }
t('gc in block') { r = []; BIG2.first(500).each { |x| GC.start; r << x.to_s }; r.size }
t('gc in map') { BIG2.first(500).map { |x| GC.start; [x.to_s] }.size }
t('gc in select') { BIG2.first(500).select { |x| GC.start; x.to_s.size > 2 }.size }
t('gc in sort_by') { BIG2.first(200).sort_by { |x| GC.start; x.to_s }.first }
t('gc in inject') { BIG2.first(300).inject([]) { |a, x| GC.start; a << x.to_s }.size }
t('gc in bag each_slice') { BAG2.each_slice(5) { |s| GC.start }.class }
t('gc in group_by') { BIG2.first(300).group_by { |x| GC.start; x.to_s.size }.keys }
t('gc in hash') { HB2.map { |k, v| GC.start if k % 500 == 0; v }.size }
t('gc in zip') { BIG2.first(200).zip(BIG2.first(200).map { |x| GC.start; x.to_s }).size }

# non-local control flow through compiled frames
t('break map') { BIG2.map { |x| break x if x == 5 } }
t('break select') { BIG2.select { |x| break :sel if x == 5 } }
t('break inject') { BIG2.inject(0) { |s, x| break s if x == 5; s + x } }
t('break sort_by') { BIG2.sort_by { |x| break :sb } }
t('break sort') { BIG2.sort { |a, b| break :s } }
t('break bag') { BAG2.map { |x| break x if x == 7 } }
t('break each_slice') { BIG2.each_slice(3) { |s| break s } }
t('break upto') { 1.upto(10) { |i| break i * 2 if i == 4 } }
t('break hash') { HB2.each { |k, v| break v if k == 3 } }
t('break range') { (1..10).each { |i| break i if i == 3 } }
t('break times') { 10.times { |i| break i if i == 3 } }
t('break nested') { BIG2.each { |x| BIG2.each { |y| break }; break :outer if x == 2 } }
t('break gsub') { 'abc'.gsub('b') { break :g } }
t('break flat_map') { BIG2.flat_map { |x| break :fm } }
t('break min_by') { BIG2.min_by { |x| break :mb } }
t('break group_by') { BIG2.group_by { |x| break :gb } }
t('break any') { BIG2.any? { |x| break :any } }
t('break find') { BIG2.find { |x| break :find } }
t('break each_with_index') { BIG2.each_with_index { |x, i| break [x, i] } }
t('break each_with_object') { BIG2.each_with_object([]) { |x, m| break m } }
t('break count') { BIG2.count { |x| break :c } }
t('break sum') { BIG2.sum { |x| break :sum } }
t('break zip') { BIG2.zip(BIG2) { |x| break :z } }
t('break uniq') { BIG2.uniq { |x| break :u } }
t('break tally') { BIG2.first(3).tally }
t('break transform') { HB2.transform_values { |v| break :tv } }
t('break fetch') { BIG2.fetch(10**6) { |i| break :f } }
t('break loop') { loop { break :l } }
def r1(a); a.each { |x| return x if x > 3 }; :no; end
def r2(a); a.map { |x| return x if x > 3; x }; end
def r3(a); a.select { |x| return :sel if x > 3 }; end
def r4(a); a.inject(0) { |s, x| return s if x > 3; s + x }; end
def r5(a); a.sort_by { |x| return :sb }; end
def r6(b); b.map { |x| return x if x > 3 }; end
def r7; 1.upto(9) { |i| return i if i > 3 }; end
def r8(h); h.each { |k, v| return k if v.size > 0 }; end
def r9(a); a.each_slice(2) { |s| return s }; end
def r10(a); a.group_by { |x| return :gb }; end
def r11; 'abc'.gsub('b') { return :g }; end
def r12(a); a.each_with_index { |x, i| return [x, i] if i > 1 }; end
def r13(a); a.any? { |x| return :any }; end
def r14(a); a.find { |x| return :f }; end
def r15(a); a.min_by { |x| return :m }; end
def r16(r); r.each { |x| return x if x > 2 }; end
t('return each') { r1(BIG2) }
t('return map') { r2(BIG2) }
t('return select') { r3(BIG2) }
t('return inject') { r4(BIG2) }
t('return sort_by') { r5(BIG2) }
t('return bag map') { r6(BAG2) }
t('return upto') { r7 }
t('return hash') { r8(HB2) }
t('return each_slice') { r9(BIG2) }
t('return group_by') { r10(BIG2) }
t('return gsub') { r11 }
t('return ewi') { r12(BIG2) }
t('return any') { r13(BIG2) }
t('return find') { r14(BIG2) }
t('return min_by') { r15(BIG2) }
t('return range') { r16(1..10) }
t('return in proc') { pr = proc { |x| next x * 2 }; BIG2.first(3).map(&pr) }
t('return lambda') { l = lambda { |x| return x * 2 }; BIG2.first(3).map(&l) }
t('throw catch') { catch(:done) { BIG2.each { |x| throw :done, x if x == 4 } } }
t('throw through map') { catch(:done) { BIG2.map { |x| throw :done, x if x == 4 } } }
t('throw through bag') { catch(:done) { BAG2.select { |x| throw :done, x if x == 4 } } }
t('raise through') { BIG2.map { |x| raise IOError, 'io' if x == 3 } }
t('raise ensure order') do
  log = []
  begin
    BIG2.each do |x|
      begin
        raise 'r' if x == 2
      ensure
        log << [:ens, x]
      end
    end
  rescue => e
    log << e.message
  end
  log
end
t('rescue in block') { BIG2.first(4).map { |x| begin; raise 'r' if x == 2; x; rescue; :rescued; end } }
t('retry-like') { n = 0; begin; n += 1; BIG2.each { |x| raise 'again' if n < 3 }; rescue; retry; end; n }
t('stack overflow') { def so(n); [n].each { |x| so(x + 1) }; end; begin; so(0); rescue SystemStackError => e; e.class; end }
t('stack overflow map') { def so2(n); [n].map { |x| so2(x + 1) }; end; begin; so2(0); rescue SystemStackError => e; e.class; end }
t('exception in each_slice') { BIG2.each_slice(2) { |s| raise 'x' } }
t('exception class') { BIG2.each { |x| raise Class.new(StandardError), 'anon' }.class rescue $!.message }
t('ensure runs on break') { log = []; BIG2.each { |x| begin; break; ensure; log << :e; end }; log }
t('ensure runs on return') { def er; [1].each { |x| begin; return 1; ensure; $er = :e; end }; end; [er, $er] }
t('block local jump') { pr = proc { break }; [1].each(&pr) }
t('orphan return') { def mk; proc { return 1 }; end; [1].each(&mk) }
t('lambda break') { l = lambda { |x| break 5 }; [1].map(&l) }
t('yield to nil') { def ynil; yield; end; ynil }
t('block arity lambda') { [[1, 2]].each(&->(a) { a }) }
t('block arity lambda2') { [[1, 2]].each(&->(a, b) { a }) }
t('proc arity map') { [[1, 2]].map(&proc { |a, b| b }) }
t('each_with_index proc') { [[1, 2]].each_with_index.map(&proc { |(a, b), i| [a, b, i] }) }
t('hash each arity') { { 1 => 2 }.map(&proc { |a, b| [a, b] }) }
t('hash each lambda') { { 1 => 2 }.each(&->(a) { a }) }
t('hash each lambda2') { { 1 => 2 }.each(&->(a, b) { [a, b] }) }
t('hash map lambda') { { 1 => 2 }.map(&->(a) { a }) }
t('hash select arity') { { 1 => 2 }.select(&proc { |a| a }) }
t('inject sym block') { [1, 2, 3].inject(:+) { |a, b| a * b } }
t('sum lambda') { [1, 2].sum(&->(x) { x * 2 }) }
t('sort block lambda') { [3, 1].sort(&->(a, b) { a <=> b }) }
t('min lambda') { [3, 1].min(&->(a, b) { a <=> b }) }

def lret; loop { return :ret }; end
def lret2(a); i = 0; loop { i += 1; return i if i > a }; end
t('loop break') { i = 0; loop { i += 1; break i * 2 if i > 3 } }
t('loop break nil') { loop { break } }
t('loop next') { i = 0; r = []; loop { i += 1; next if i.odd?; r << i; break if i > 6 }; r }
t('loop stop result') { e = [1, 2].each; r = []; [loop { r << e.next }, r] }
t('loop stop') { loop { raise StopIteration } }
t('loop stop msg') { loop { raise StopIteration, 'x' } }
t('loop other') { loop { raise IOError, 'io' } }
t('loop ensure') { log = []; begin; loop { begin; raise IOError; ensure; log << :e; end }; rescue IOError; log << :r; end; log }
t('loop ret') { lret }
t('loop ret2') { lret2(5) }
t('loop nested') { r = []; i = 0; loop { j = 0; loop { j += 1; break if j > 2 }; i += 1; r << [i, j]; break if i > 1 }; r }
t('loop none') { loop.class }
t('loop args') { loop(1) { break } }
t('loop custom stop') { class MyStop < StopIteration; def result; :mine; end; end; loop { raise MyStop } }
t('loop in fiber') { f = Fiber.new { i = 0; loop { Fiber.yield i; i += 1; break if i > 2 }; :done }; Array.new(4) { f.resume } }
t('loop throw') { catch(:x) { loop { throw :x, 5 } } }
t('loop gc') { n = 0; loop { n += 1; GC.start if n % 100 == 0; break if n > 2000 }; n }
t('loop big') { n = 0; loop { n += [n].size; break if n > 50000 }; n }
puts 'END'
