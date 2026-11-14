#!/usr/bin/env ruby
# The C compiler of `nfcxx --target=linux_k1om` (the gcc backend for Intel Knights Corner, k1om). It is gcc-cc's
# NFCXX_GCC: the k1om GCC 5.1.1 (Intel's MPSS 3.8.6 toolchain, rebuilt for a modern host; docs/notes/k1om.md).
# gcc-cc passes flags from newer GCCs: map or drop the ones GCC 5 lacks. Linking uses the k1om libC.a of
# build/k1om (setup-k1om.sh), not the host's EDG runtime, which is host code.

# A variable that is unset or empty is nil (bash's ${VAR:-default}).
def env(name)
  v = ENV[name]
  v.nil? || v.empty? ? nil : v
end

root = File.expand_path("..", File.expand_path(File.dirname($0)))
k1om = env("NFCXX_K1OM_ROOT") || "/opt/k1om"
libdir = env("NFCXX_K1OM_LIBDIR") || "#{root}/build/k1om"
link = true
ARGV.each { |a| link = false if %w[-c -E -S].include?(a) }
args = []
ARGV.each do |a|
  case a
  when "-std=gnu17" then a = "-std=gnu1x"
  when "-std=c17", "-std=c18" then a = "-std=c1x"
  when "-fdiagnostics-plain-output", "-fkeep-static-functions" then next
  when /build\/edg\/lib/ then next if link
  end
  args << a
end
args << "-L#{libdir}" if link
begin
  Kernel.exec("#{k1om}/bin/k1om-mpss-linux-gcc", "-B#{root}/scripts/k1om-bin/", *args)
rescue SystemCallError => e
  warn "k1om-cc: #{e.message}"
  exit 127
end
