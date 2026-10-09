# Small script for tests/realworld/run_mruby.sh: strings, arrays, hashes, blocks, exceptions.
# The last line is the marker the runner checks.
s = "mruby"
s2 = s + "-" + s.upcase
raise "string" unless s2 == "mruby-MRUBY" && s2.length == 11 && "a,b,c".split(",") == ["a", "b", "c"]
raise "format" unless format("%05.1f|%-4s|%x", 3.14159, "ab", 255) == "003.1|ab  |ff"

a = [5, 3, 8, 1]
raise "array" unless a.sort == [1, 3, 5, 8] && a.map { |x| x * 2 }.reduce(:+) == 34 && a.select(&:odd?).size == 3

h = { "one" => 1, two: 2 }
h[:three] = 3
raise "hash" unless h.size == 3 && h["one"] == 1 && h.keys.size == 3 && h.values.sum == 6

def twice; yield; yield; end
n = 0
twice { n += 21 }
raise "block" unless n == 42
add = ->(x, y) { x + y }
raise "lambda" unless add.(2, 3) == 5

class MyError < StandardError; end
r = begin
  raise MyError, "boom"
rescue MyError => e
  e.message
ensure
  n += 1
end
raise "rescue" unless r == "boom" && n == 43

def deep(k); k == 0 ? raise(ArgumentError, "deep") : deep(k - 1); end
c = begin; deep(50); rescue => e; e.class; end
raise "nested raise" unless c == ArgumentError

x = catch(:done) { 10.times { |i| throw :done, i if i == 4 }; :never }
raise "catch/throw" unless x == 4

fib = Hash.new { |hh, k| hh[k] = k < 2 ? k : hh[k - 1] + hh[k - 2] }
raise "fib" unless fib[20] == 6765
puts "mruby-ok #{RUBY_ENGINE} #{h.size} #{a.sort.inspect} #{fib[20]}"
