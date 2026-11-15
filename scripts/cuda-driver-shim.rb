#!/usr/bin/env ruby
# The CUDA driver API through the CUDA runtime (docs/notes/cuda-driver.md): builds libnfcxx_cudrv.a, whose cu* functions
# (cuInit, cuModuleLoadData, cuLaunchKernel, ...) look the driver's own function up through libcudart's
# cudaGetDriverEntryPointByVersion on their first call and jump to it. nfcxx and nfcc link it in place of libcuda
# (scripts/wrap.rb). A program linked with it and libcudart does not need libcuda.so.1 to link or to start (cudart loads the driver when it is first used), and a bundle
# (docs/notes/bundle.md) does not name the driver in DT_NEEDED. x86-64 Linux.
#   usage: scripts/cuda-driver-shim.rb [INCLUDE_DIR]   prints the archive's path
#   INCLUDE_DIR holds cuda.h and cudaTypedefs.h (default: $CUDA_HOME/include, else /usr/local/cuda/include).
# Each linked name has its own ABI version: cuCtxCreate is cuCtxCreate_v2, the 3.2 ABI, while the base name cuCtxCreate
# at CUDA 12.9 is the 12.5 one (_v4, other arguments). So the version asked for is the one whose typedef in
# cudaTypedefs.h (PFN_cuCtxCreate_v3020, ...) has the function's own type, which gcc decides
# (__builtin_types_compatible_p) in a probe compiled once per header, with and without the per-thread default stream.
# The archive is cached under build/cuda-driver/<hash of the headers and the sources>.
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
$stdout.sync = true
$stderr.sync = true

def errno_text(err)
  SystemCallError.new(nil, err.errno).message
end

# A command as the shell runs it, with its output going to the script's stdout: returns its status. A command that
# cannot be found has the status 127, after the shell's message (LINE is the original script's line for it).
def run(argv, line)
  ok = system([argv[0], argv[0]], *argv[1..])
  if ok.nil?
    warn "#{$PROGRAM_NAME}: line #{line}: #{argv[0]}: command not found"
    return 127
  end
  $?.exitstatus || (128 + $?.termsig)
end

def capture(argv, line, stdin_data = "")
  out, st = Open3.capture2([argv[0], argv[0]], *argv[1..], stdin_data: stdin_data)
  [out, st.exitstatus || (128 + st.termsig)]
rescue Errno::ENOENT
  warn "#{$PROGRAM_NAME}: line #{line}: #{argv[0]}: command not found"
  ["", 127]
end

# The probe, per mode: for each driver function declared, every typedef of its base (base, version, per-thread suffix:
# the ones the preprocessed cudaTypedefs.h declares) with the same type. Returns the probe program's output; a failing
# step ends the script with its status, as set -e and pipefail do in the original.
def probe(cc, inc, tmp, define)
  m = define.empty? ? [] : [define]
  pp, st = capture([cc, "-E", "-P", *m, "-I#{inc}", "-x", "c", "-"], 33,
                   "#include <cuda.h>\n#include <cudaTypedefs.h>\n")
  exit st unless st.zero?

  # sed -nE 's/^(extern )?CUresult (cu[A-Za-z0-9_]+) *\(.*/\2/p' | sort -u
  names = pp.each_line.filter_map { |l| l.chomp[/\A(?:extern )?CUresult (cu[A-Za-z0-9_]+) *\(/, 1] }.uniq.sort

  # grep -oE 'typedef CUresult \( *\*PFN_cu...' | sed -E 's/.*\*PFN_(cu...)_v([0-9]+)(_ptds|_ptsz)?\)/\1 \2 \3/' | sort -u
  # (grep finds no typedef: its status 1 ends the script under pipefail, silently)
  pfn = pp.scan(/typedef CUresult \( *\*PFN_cu[A-Za-z0-9_]+_v[0-9]+(?:_ptds|_ptsz)?\)/).filter_map do |t|
    t.match(/\A.*\*PFN_(cu[A-Za-z0-9_]+)_v([0-9]+)(_ptds|_ptsz)?\)/) && "#{$1} #{$2} #{$3}"
  end.uniq.sort
  exit 1 if pfn.empty?

  c = +"#include <stdio.h>\n#include <cuda.h>\n#include <cudaTypedefs.h>\nint main(void) {\n"
  names.each do |f|
    base = f
    pt = ""
    if base.match?(/_(ptds|ptsz)\z/)
      idx = base.rindex("_")
      pt = base[(idx + 1)..]
      base = base[0...idx]
    end
    base = base.sub(/_v[0-9]+\z/, "")
    flag = pt.empty? ? "legacy" : pt
    any = false
    pfn.each do |line|
      b, v, s = line.split(" ")
      s ||= ""
      next unless b == base
      next unless s.sub(/\A_/, "") == pt

      any = true
      c << "  if (__builtin_types_compatible_p(__typeof__(&#{f}), PFN_#{b}_v#{v}#{s})) printf(\"#{f} #{b} #{v} #{flag}\\n\");\n"
    end
    c << "  printf(\"#{f} #{base} 0 #{flag}\\n\");\n" unless any
  end
  c << "  return 0;\n}\n"
  File.binwrite("#{tmp}/probe.c", c)

  st = run([cc, "-w", *m, "-I#{inc}", "#{tmp}/probe.c", "-o", "#{tmp}/probe"], 58)
  exit st unless st.zero?
  out, st = capture(["#{tmp}/probe"], 58)
  exit st unless st.zero?
  out
end

root = File.expand_path("..", File.dirname($PROGRAM_NAME))
cuda_home = ENV["CUDA_HOME"].to_s
inc = ARGV[0].to_s.empty? ? "#{cuda_home.empty? ? "/usr/local/cuda" : cuda_home}/include" : ARGV[0]
nfcxx_gcc = ENV["NFCXX_GCC"].to_s
cc = nfcxx_gcc.empty? ? "gcc" : nfcxx_gcc

%w[cuda.h cudaTypedefs.h].each do |f|
  next if File.file?("#{inc}/#{f}")

  warn "cuda-driver-shim: #{inc}/#{f} not found (give the CUDA include directory)"
  exit 1
end
machine, = capture(["uname", "-m"], 21)
unless machine.sub(/\n+\z/, "") == "x86_64"
  warn "cuda-driver-shim: x86-64 only"
  exit 1
end

src = "#{root}/lib/cuda/driver/nfcxx_cudrv.c"
# key=$(cat HEADERS SRC "$0" | sha256sum | cut -c1-16): a file that cannot be read ends the script (pipefail)
cat_failed = false
data = +"".b
["#{inc}/cuda.h", "#{inc}/cudaTypedefs.h", src, $PROGRAM_NAME].each do |f|
  data << File.binread(f)
rescue SystemCallError => e
  warn "cat: #{f}: #{errno_text(e)}"
  cat_failed = true
end
exit 1 if cat_failed
key = Digest::SHA256.hexdigest(data)[0, 16]
out = "#{root}/build/cuda-driver/#{key}"
lib = "#{out}/libnfcxx_cudrv.a"
if File.file?(lib)
  puts lib
  exit 0
end

Dir.mktmpdir("cuda-driver-shim") do |tmp|
  define_ptds = "-DCUDA_API_PER_THREAD_DEFAULT_STREAM"
  # { probe ""; probe -DCUDA_API_PER_THREAD_DEFAULT_STREAM; } | sort -u > matches
  combined = probe(cc, inc, tmp, "") + probe(cc, inc, tmp, define_ptds)
  matches = combined.lines.map { |l| l.chomp }.uniq.sort

  # The versions: ver is CUDA_VERSION of cuda.h (its first line; "" when there is none)
  cv = File.binread("#{inc}/cuda.h").each_line.filter_map { |l| l[/\A#define CUDA_VERSION ([0-9]+)/, 1] }.first.to_s

  # sort -k1,1 -k3,3n matches | awk: one X(...) row per name. The name's base and flag are those of its last line; the
  # version is the k-th of its ascending versions (k: the number of its _vN suffix, 1 for a name without one), clamped
  # to the count, and the header's CUDA_VERSION for a version of 0.
  sorted = matches.sort_by { |l| f = l.split(" "); [f[0], f[2].to_i, l] }
  groups = {}
  sorted.each do |line|
    n, bse, ver, flag = line.split(" ")
    g = (groups[n] ||= { vers: [], base: nil, flag: nil })
    g[:vers] << ver
    g[:base] = bse
    g[:flag] = flag
  end
  rows = groups.map do |n, g|
    count = g[:vers].size
    k = 1
    if (m = /_v[0-9]+(?:_ptds|_ptsz)?\z/.match(n))
      k = n[(m.begin(0) + 2)..].sub(/_.*/, "").to_i
    end
    k = 1 if count == 1
    k = count if k > count
    v = k >= 1 ? g[:vers][k - 1] : nil
    x = v.nil? || v.to_i.zero? ? cv : v
    "X(#{n}, \"#{g[:base]}\", #{x}, #{g[:flag] == "legacy" ? 1 : 2})"
  end.sort

  FileUtils.mkdir_p("#{tmp}/o")
  File.binwrite("#{tmp}/o/matches.txt", matches.map { |l| "#{l}\n" }.join)   # every compatible typedef, for review
  File.binwrite("#{tmp}/o/nfcxx_cudrv_table.inc", rows.map { |r| "#{r}\n" }.join)
  n = rows.size
  unless n > 100
    warn "cuda-driver-shim: only #{n} driver functions found in #{inc}/cuda.h"
    exit 1
  end

  st = run([cc, "-c", "-O2", "-fPIC", "-I#{tmp}/o", src, "-o", "#{tmp}/o/nfcxx_cudrv.o"], 82)
  exit st unless st.zero?
  st = run(["ar", "rcs", "#{tmp}/o/libnfcxx_cudrv.a", "#{tmp}/o/nfcxx_cudrv.o"], 83)
  exit st unless st.zero?

  # mkdir -p "$(dirname "$out")"; cp -r into OUT.tmp.PID, then mv it into place (a concurrent build may have made it first)
  begin
    FileUtils.mkdir_p(File.dirname(out))
  rescue SystemCallError => e
    warn "mkdir: cannot create directory '#{File.dirname(out)}': #{errno_text(e)}"
    exit 1
  end
  staged = "#{out}.tmp.#{Process.pid}"
  FileUtils.rm_rf(staged)
  begin
    FileUtils.cp_r("#{tmp}/o", staged)
  rescue SystemCallError => e
    warn "cp: cannot create directory '#{staged}': #{errno_text(e)}"
    exit 1
  end
  begin
    # mv into an existing directory moves the staged one inside it
    target = File.directory?(out) ? "#{out}/#{File.basename(staged)}" : out
    File.rename(staged, target)
  rescue SystemCallError
    FileUtils.rm_rf(staged)
  end
end
puts lib
