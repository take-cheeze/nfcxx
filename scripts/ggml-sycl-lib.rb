#!/usr/bin/env ruby
# Build llama.cpp's SYCL backend (ggml/src/ggml-sycl, unchanged) into a libggml-sycl.so with nfcxx: every source is a
# separate scripts/sycl-build.rb -c compile (the device image beside each object, lib/sycl/include/sycl/rt_image.hpp),
# then one nfcxx -shared link against the libggml-base.so of a llama.cpp build. The library has the SONAME of the CMake
# build (libggml-sycl.so.0), so a ggml program finds it in place of the icpx one through LD_LIBRARY_PATH.
#
#   scripts/ggml-sycl-lib.rb [-j N] [--backend=level-zero|opencl] OUTDIR
#
# One source is replaced by lib/sycl-ggml/stubs: fused-gemm.cpp (joint_matrix; the stubs decline, so the unfused path
# runs). The oneMKL calls (gemm, gemm_batch, trsm_batch) are lib/sycl-ggml/oneapi/mkl.hpp's reference kernels. The macros
# are tests/gpu/ggml/sweep.sh's. A compile that fails is listed with its first error and the link is not run (exit 1).
# Objects are kept in OUTDIR/obj and rebuilt when missing or older than their source, a header of lib/sycl or
# lib/sycl-ggml, or the compilers (build/pathb, build/edg, build/qbe and their scripts).
# Env: GGML_SRC (the ggml-sycl source dir), GGML_BUILD (the bin dir with libggml-base.so), SPIRV_TOOLS_BIN.
require "fileutils"
$stdout.sync = true
$stderr.sync = true

def envd(name, default)
  v = ENV[name].to_s
  v.empty? ? default : v
end

def run_status(env, argv, out: nil, err_to_out: false)
  opts = {}
  opts[:out] = out if out
  opts[:err] = [:child, :out] if err_to_out
  ok = system(env, [argv[0], argv[0]], *argv[1..], **opts)
  return 127 if ok.nil?

  $?.exitstatus || (128 + $?.termsig)
end

# bash -nt: a is newer than b (a missing b counts as older; a missing a is never newer)
def newer?(a, b)
  return false unless File.exist?(a)
  return true unless File.exist?(b)

  File.mtime(a) > File.mtime(b)
end

# Every regular file under a path (find PATH -type f), nothing for a missing path
def files_under(path)
  return [path] if File.file?(path) && !File.symlink?(path)
  return [] unless Dir.exist?(path)

  Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) && !File.symlink?(f) }
end

# a bash glob: the matches in sorted order, or the pattern itself when nothing matches
def glob_or_literal(pattern)
  found = Dir.glob(pattern).sort
  found.empty? ? [pattern] : found
end

ENV["PATH"] = envd("SPIRV_TOOLS_BIN", "").then { |s| s.empty? ? ENV["PATH"] : "#{s}:#{ENV['PATH']}" }
root = File.expand_path("..", File.dirname($PROGRAM_NAME))
ggml_src = envd("GGML_SRC", "/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl")
ggml_build = envd("GGML_BUILD", "/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin")
jobs = 4
backend = "level-zero"
outdir = ""
argv = ARGV.dup
while (a = argv.shift)
  case a
  when "-j"
    v = argv.shift
    exit 1 if v.nil?
    jobs = v
  when /\A--backend=/ then backend = a.delete_prefix("--backend=")
  when /\A-/
    warn "ggml-sycl-lib: unknown option #{a}"
    exit 2
  else outdir = a
  end
end
if outdir.empty?
  warn "usage: ggml-sycl-lib.rb [-j N] [--backend=level-zero|opencl] OUTDIR"
  exit 2
end
rtlib = case backend
        when "level-zero" then "-l:libze_loader.so.1"
        when "opencl" then "-l:libOpenCL.so.1"
        else
          warn "ggml-sycl-lib: --backend must be level-zero or opencl"
          exit 2
        end
jobs = jobs.to_i
FileUtils.mkdir_p(File.join(outdir, "obj"))
outdir = File.expand_path(outdir)
stubs = File.join(root, "lib/sycl-ggml/stubs")
# the newest input every object depends on: a stamp file dated like it
stamp = File.join(outdir, "obj", ".inputs")
inputs = [
  "lib/sycl", "lib/sycl-ggml", "scripts/sycl-build.rb", "scripts/pathb-spirv-emit.rb",
  "build/pathb/cmake/bin/cpfe", "build/edg/bin/cpfe", "build/qbe/qbe",
  "scripts/weak-symbols", "tools/weak-symbols/weak_symbols.cpp", "nfcxx"
].flat_map { |p| files_under(File.join(root, p)) }
newest_entry = inputs.map { |f| [File.mtime(f).to_f, f] }.max
newest = newest_entry ? newest_entry[1] : ""
run_status({}, ["touch", "-r", newest, stamp])

srcs = []
glob_or_literal(File.join(ggml_src, "*.cpp")).each do |f|
  b = File.basename(f)
  srcs << (File.file?(File.join(stubs, b)) ? File.join(stubs, b) : f)
end
# the flash-attention template instances, as ggml-sycl's CMakeLists.txt adds them
%w[fattn-tile*.cpp fattn-vec*.cpp].each do |pat|
  srcs.concat(glob_or_literal(File.join(ggml_src, "template-instances", pat)))
end

sycl_build = File.join(root, "scripts/sycl-build.rb")
compile_args = %W[
  --backend=#{backend} -c -fPIC --ndebug --no-div-trap --diag_warning=narrowing_conversion -Wno-error=template-body
  -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED -DGGML_BACKEND_BUILD -DGGML_BACKEND_SHARED -DGGML_SCHED_MAX_COPIES=4
  -DGGML_SYCL_DNNL=0 -DGGML_SYCL_F16 -DGGML_SYCL_HAS_BF16 -DGGML_SYCL_DMMV_HAS_BF16 -DGGML_SYCL_HOST_MEM_FALLBACK
  -D_GNU_SOURCE -D_XOPEN_SOURCE=600 -Dggml_sycl_EXPORTS
  -I#{root}/lib/sycl-ggml -I#{ggml_src} -I#{ggml_src}/../../include -I#{ggml_src}/..
]

# one SRC: compiles one source to OUTDIR/obj/NAME.o; returns "NAME: ok (Ns)", "NAME: FAIL" and the first error, or "NAME: ok (kept)"
def one(f, outdir, stamp, root, ggml_src, sycl_build, compile_args)
  b = File.basename(f, ".cpp")
  log = File.join(outdir, "obj", "#{b}.log")
  obj = File.join(outdir, "obj", "#{b}.o")
  if File.file?(obj) && newer?(obj, f) && newer?(obj, stamp)
    return "#{b}: ok (kept)\n"
  end

  s = Time.now.to_i
  st = run_status({}, [sycl_build, *compile_args, f, "-o", obj], out: log, err_to_out: true)
  if st.zero?
    return "#{b}: ok (#{Time.now.to_i - s}s)\n"
  end

  FileUtils.rm_f(obj)
  text = File.read(log).lines
  idx = text.index { |l| l.match?(/error|refused|undefined/i) }
  chunk = idx ? text[idx, 3].join : ""
  # tr -s ' \n' ' ': each newline becomes a space, then each run of spaces is squeezed; cut -c1-240; the
  # command substitution strips trailing newlines only
  chunk = chunk.tr("\n", " ").gsub(/ {2,}/, " ")
  first = chunk[0, 240].sub(/\n+\z/, "")
  "#{b}: FAIL #{first}\n"
end

results = []
mutex = Mutex.new
queue = Queue.new
srcs.each { |f| queue << f }
workers = jobs <= 0 ? srcs.size : [jobs, 1].max
threads = Array.new([workers, srcs.size].min) do
  Thread.new do
    loop do
      f = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      r = one(f, outdir, stamp, root, ggml_src, sycl_build, compile_args)
      mutex.synchronize { results << r }
    end
  end
end
threads.each(&:join)

lines = results.join.split("\n").sort
File.write(File.join(outdir, "compile.txt"), lines.map { |l| "#{l}\n" }.join)
lines.each { |l| puts l }
nfail = lines.count { |l| l.include?(": FAIL") }
if nfail.positive?
  puts "ggml-sycl-lib: #{nfail} of #{srcs.size} sources failed; not linking"
  exit 1
end

objs = glob_or_literal(File.join(outdir, "obj", "*.o"))
link_log = File.join(outdir, "link.log")
st = run_status({}, [File.join(root, "nfcxx"), "-shared", *objs, "-o", File.join(outdir, "libggml-sycl.so.0"),
                     "-Wl,-soname,libggml-sycl.so.0", "-L#{ggml_build}", "-lggml-base", "-Wl,-rpath,#{ggml_build}", rtlib],
                out: link_log, err_to_out: true)
unless st.zero?
  puts "ggml-sycl-lib: link FAIL"
  File.readlines(link_log).reject { |l| l.include?("prelinker") }.first(20).each { |l| puts l.chomp }
  exit 1
end
FileUtils.ln_sf("libggml-sycl.so.0", File.join(outdir, "libggml-sycl.so"))
puts "ggml-sycl-lib: #{outdir}/libggml-sycl.so.0 (#{objs.size} objects)"
