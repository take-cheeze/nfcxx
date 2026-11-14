#!/usr/bin/env ruby
# setup-k1om: the runtime for `nfcxx --target=linux_k1om` (Intel Knights Corner). Needs the k1om toolchain at
# NFCXX_K1OM_ROOT (default /opt/k1om; docs/notes/k1om.md). Builds:
#   build/edg-k1om      the EDG front end and its runtime sources, for the host (host tools only)
#   build/k1om/libC.a   EDG's C++ runtime compiled for k1om, through the same gcc-cc chain the programs use
# c99_complex.c is left out: it needs _Float16 and __bf16, which the host front end does not give GCC 5.
# Idempotent: rebuilds only when build/k1om/libC.a is missing.
require_relative "setup-common"
include SetupCommon

root = root_of(__FILE__)
k1om = env_or("NFCXX_K1OM_ROOT", "/opt/k1om")
unless File.executable?("#{k1om}/bin/k1om-mpss-linux-gcc")
  die("setup-k1om: no k1om gcc at #{k1om}/bin (build the toolchain: docs/notes/k1om.md)")
end
if File.file?("#{root}/build/k1om/libC.a")
  puts "k1om runtime: already built (#{root}/build/k1om/libC.a)"
  exit 0
end

# 1. The host EDG tree, separate from build/edg so the native build is not touched.
edg_env = { "NFCXX_GCC" => nil, "NFCXX_CC" => nil, "NFCXX_AS" => nil,
            "EDG_BUILD" => "#{root}/build/edg-k1om", "EDG_BASE" => "#{root}/build/edg-base-k1om" }
edg = run(edg_env, "#{root}/scripts/setup-edg.sh", chdir: root,
          out: "#{root}/build/edg-k1om.log", err: [:child, :out])
die("setup-k1om: EDG build failed (see build/edg-k1om.log)") unless edg.success?

# 2. The runtime: the compile commands ninja would run for lib/libC.a, run with the k1om compiler chain.
Dir.chdir("#{root}/build/edg-k1om")
ninja_out = capture("ninja", "-t", "commands", "lib/libC.a")[0]
cmds = ninja_out.lines.map(&:chomp).select do |line|
  (line.include?("rt-cache") || line.include?("lib_src")) && !line.include?(" ar qc") && !line.include?("c99_complex")
end
die("setup-k1om: no runtime compile commands in build/edg-k1om") if cmds.empty?

ENV["NFCXX_GCC"] = "#{root}/scripts/k1om-cc"
ENV["NFCXX_CC"] = "#{root}/scripts/gcc-cc"
ENV["NFCXX_AS"] = "#{root}/scripts/k1om-bin/as"
ENV["NFCXX_K1OM_ROOT"] = k1om
ENV["NFCXX_CCACHE"] = "0"
rt_log = "#{root}/build/edg-k1om-rt.log"
cmds.each do |c|
  next if run("bash", "-c", c, out: rt_log, err: [:child, :out]).success?

  $stderr.puts "setup-k1om: runtime compile failed: #{c[0, 160]}"
  File.foreach(rt_log).select { |l| l.include?("error") }.first(3).each { |l| $stderr.print l }
  exit 1
end

# 3. Archive the objects with the k1om ar, without c99_complex.
must("mkdir", "-p", "#{root}/build/k1om")
objs = Dir.glob("*.o", base: "lib_src/edg-cpp-rt-cache").sort.reject { |o| o == "c99_complex.o" }
must("rm", "-f", "#{root}/build/k1om/libC.a")
must("#{k1om}/bin/k1om-mpss-linux-ar", "rcs", "#{root}/build/k1om/libC.a", *objs,
     chdir: "lib_src/edg-cpp-rt-cache")
puts "k1om runtime: #{root}/build/k1om/libC.a (#{objs.size} objects)"
