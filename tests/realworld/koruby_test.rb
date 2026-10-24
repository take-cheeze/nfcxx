# Run by tests/realworld/run_astro.sh on koruby_precise (ASTro's CRuby-compatible Ruby) built by nfcc. The expected output
# is koruby_test.expected, which CRuby prints too; only forms that CRuby 3.3 and 3.4 print alike are used.
def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)
puts fib(22)
puts [5, 3, 9, 1].sort.inspect
puts [3, 1, 2].map { |x| x * x }.inspect
h = { "b" => 2, "a" => 1 }
puts h.sort.map { |k, v| "#{k}=#{v}" }.join(",")
class Pt
  attr_reader :x
  def initialize(x) = @x = x
  def +(o) = Pt.new(@x + o.x)
  include Comparable
  def <=>(o) = @x <=> o.x
end
puts (Pt.new(2) + Pt.new(3)).x
puts [Pt.new(3), Pt.new(1)].min.x
begin
  raise ArgumentError, "boom"
rescue => e
  puts "#{e.class}: #{e.message}"
end
puts "hello world".sub(/o w/, "0W").upcase
puts "a1b22c333".scan(/\d+/).inspect
puts (1..10).select(&:even?).sum
puts [1, 2, 3, 4, 5].each_slice(2).to_a.inspect
puts format("%05.1f|%-4s|%x", 3.14159, "ab", 255)
S = Struct.new(:a, :b)
s = S.new(1, 2)
puts s.a + s.b
puts "snake_case_word".split("_").map(&:capitalize).join
x = 0
10.times { |i| x += i if i.odd? }
puts x
puts (1..5).reduce(:*)
puts "ok" if "abc" =~ /b(c)/ && $1 == "c"
