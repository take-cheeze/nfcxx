# The closed-world Regexp and ENV (bc2cpp/tools/script_world/sealed_build.rb): the same answers compiled and interpreted.
def main(argv)
  puts "gsub: #{"abc123".gsub(/\d/, "x")}"
  m = /b(.)/.match("abc")
  puts "match: #{m ? m[1] : 'none'}"
  puts "scan: #{"a1b22".scan(/\d+/).inspect}"
  puts "env key?: #{ENV.key?('PATH')}"
  puts "env []: #{ENV['NO_SUCH_VAR_NFCXX'].inspect}"
  puts "env fetch: #{ENV.fetch('NO_SUCH_VAR_NFCXX', 'dflt')}"
  puts "env keys include PATH: #{ENV.keys.include?('PATH')}"
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
