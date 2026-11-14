#!/usr/bin/env ruby
# Print the path of the device-wide CUB archive (lib/cuda/cub/device.cu: DeviceReduce::Sum, DeviceScan::InclusiveSum
# and the SortPairs sorts that ggml-cuda calls, behind the host shim lib/cuda/host/cub/cub.cuh), building it first when
# it is missing or older than its sources or the tools that build it. The driver adds it to hosted links that name
# -lcudart; it is an archive, so a program that calls none of these links none of it.
#   NFCXX_CUDA_CUB=0      print nothing (link without it)
#   NFCXX_CUDA_CUB_DIR=d  where the archive is kept (default build/cuda-cub)
# The object is compiled by nfcxx itself (its kernels go through the same device flow as any .cu input), with EDG's
# local instantiation: the archive member has no prelinker records, so each template it uses is instantiated in it.
# When it cannot be built the script prints a warning on stderr and nothing on stdout: the link then reports the CUB
# functions as undefined.
# This is scripts/cuda-cub (bash) ported to Ruby: the same checks, the same compile of the driver, the same archive.
require "fileutils"
require "tmpdir"

ROOT = File.expand_path("..", File.expand_path(File.dirname($0)))
SELF = File.expand_path(__FILE__)

def env(name)
  v = ENV[name]
  v.nil? || v.empty? ? nil : v
end

exit 0 if env("NFCXX_CUDA_CUB") == "0"
cuda = env("CUDA_HOME") || "/usr/local/cuda"
src = File.join(ROOT, "lib", "cuda", "cub", "device.cu")
backend = env("NFCXX_BACKEND") || "pathb"
sm = env("NFCXX_SM") || "75"   # the archive is device code for one architecture: keyed by it, as the driver's object cache is
dir = File.join(env("NFCXX_CUDA_CUB_DIR") || File.join(ROOT, "build", "cuda-cub"), backend, "sm#{sm}")
out = File.join(dir, "libnfcxx_cub.a")

# EDG's runtime too: an EDG rebuild can change what the generated code expects of it (the thread-local EH state).
deps = [src, File.join(ROOT, "lib", "cuda", "nfcxx_cuda.h"), File.join(ROOT, "build", "cuda-rewrite"),
        File.join(ROOT, "build", "pathb-ptx-emit"), File.join(env("EDG_BUILD") || File.join(ROOT, "build", "edg"), "lib", "libC.a"),
        SELF]
stale = !File.exist?(out) || deps.any? { |d| File.exist?(d) && File.mtime(d) > File.mtime(out) }

if stale
  FileUtils.mkdir_p(dir)
  tmp = Dir.mktmpdir(".build.", dir)
  at_exit { FileUtils.rm_rf(tmp) }
  log = File.join(tmp, "log")
  built = system({ "NFCXX_CUDA_CUB" => nil, "TMPDIR" => tmp},
                 File.join(ROOT, "nfcxx"), "--backend=#{backend}", "-c", "--instantiate=local", "-I#{cuda}/include",
                 src, "-o", File.join(tmp, "device.o"), out: log, err: [:child, :out])
  unless built
    warn "cuda-cub: cannot build #{src}; linking without it:"
    lines = File.exist?(log) ? File.readlines(log, chomp: true) : []
    matched = lines.select { |l| l.match?(/error|refused/) }
    (matched.empty? ? lines.first(5) : matched.first(5)).each { |l| warn l }
    exit 0
  end
  system("ar", "rcs", File.join(tmp, "libnfcxx_cub.a"), File.join(tmp, "device.o")) or exit($?.exitstatus || 1)
  FileUtils.mv(File.join(tmp, "libnfcxx_cub.a"), out)   # atomic: concurrent builds each write their own copy
end
puts out
