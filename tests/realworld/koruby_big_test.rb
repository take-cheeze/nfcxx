# Bignum cases for koruby_precise built with BIGNUM=gmp; run_astro.sh compares the output with koruby_big_test.expected (CRuby's).
puts 2**100
puts -(2**100)
f = 1
(1..30).each { |i| f *= i }
puts f
puts f / 12345678901234567
puts f % 12345678901234567
puts (-f) / 1000000007
puts (-f) % 1000000007
puts f.divmod(10**20).inspect
puts (2**100).to_s(16)
puts (2**100).to_s(2).size
puts (3**50).to_s(36)
puts 12345678901234567890123.digits.inspect
puts (10**25).digits(1000).inspect
puts (2**100).gcd(6**50)
puts (2**100).lcm(3**20)
puts (2**100 > 2**99)
puts (2**100 <=> 2**101)
puts (2**100 == 2**100)
puts [2**70, 2**65, -(2**80)].sort.inspect
puts [2**70, 2**65, -(2**80)].max
puts -(2**70) + 5
puts (-(2**70)).abs
puts (2**64 - 2**64).class
puts (2**64).class
puts Integer.sqrt(10**40)
puts Integer.sqrt(10**41)
puts (2**100) * 1.5
puts 1.5 * 3**60
puts (2**100).to_f
puts (2**100 + 1) - 2**100
puts (2**100).bit_length
puts (2**100) >> 90
puts 1 << 100
puts (2**100) & (2**99 + 12345)
puts (2**100).even?
puts (7**40).pow(3, 1000003)
puts "123456789012345678901234567890".to_i + 1
puts "%d" % (2**80)
puts (10**30).to_s.size
