#!/usr/bin/env ruby
# Self-hosting step 1: compile EDG's cpfe sources with nfcxx's qbe backend and link them into build/selfhost/cpfe.
#
# EDG's cmake build (scripts/setup-edg.sh) compiles the 75 front-end sources of cpfe with `g++ -x c++`, so each
# one is also a C++ input here. Each source is linked into build/selfhost/src/<name>.cpp (a symlink into 3rd/edg/src,
# nfcxx needs the .cpp suffix) and compiled by ./nfcxx with NFCXX_BACKEND=gcc, using the same defines and include
# directory as the cmake build. The objects are then linked by ./nfcxx, which adds libnfcxxld.a (scripts/qbe-cc) and
# EDG's libC.a. mk_errinfo.c is a host tool, not part of cpfe, and is skipped.
#
# Needs build/edg (scripts/setup-edg.sh) and build/qbe, build/cproc (scripts/setup-qbe.sh).
# Output: build/selfhost/cpfe (the link), build/selfhost/obj/*.o, logs in build/selfhost/run/<name>.log.
# JOBS: parallel compiles (default 4).
require "fileutils"
$stdout.sync = true
$stderr.sync = true

root = File.expand_path("..", File.dirname($PROGRAM_NAME))
edg = File.join(root, "build/edg")
base = File.join(root, "build/edg-base")
out = ENV["SELFHOST_OUT"].to_s.empty? ? File.join(root, "build/selfhost") : ENV["SELFHOST_OUT"]
jobs = ENV["JOBS"].to_s.empty? ? 4 : ENV["JOBS"].to_i

def executable?(path)
  File.executable?(path)
end

def run_status(env, *argv, **opts)
  ok = system(env, [argv[0], argv[0]], *argv[1..], **opts)
  return 127 if ok.nil?

  $?.exitstatus || (128 + $?.termsig)
end

def run!(*argv)
  st = run_status({}, *argv)
  exit st unless st.zero?
end

unless executable?(File.join(edg, "bin/cpfe"))
  warn "selfhost-cpfe: #{edg}/bin/cpfe missing; run scripts/setup-edg.sh"
  exit 2
end
unless executable?(File.join(root, "build/qbe/qbe"))
  warn "selfhost-cpfe: QBE missing; run scripts/setup-qbe.sh"
  exit 2
end

# FRONT_END=<cpfe>: use that front end in place of EDG's cpfe (stage 2 passes the stage-1 cpfe). nfcxx and eccp find cpfe
# through EDG_BUILD and build/edg/environment.sh, both with absolute paths, so $out/fe is a symlink copy of build/edg whose
# bin/cpfe, environment.sh (CPFE) and bin/eccp (the path to environment.sh) point at FRONT_END. The source list and
# include directory still come from build/edg.
fe_build = edg
front_end = ENV["FRONT_END"].to_s
unless front_end.empty?
  unless executable?(front_end)
    warn "selfhost-cpfe: FRONT_END=#{front_end} is not executable"
    exit 2
  end
  fe_build = File.join(out, "fe")
  FileUtils.rm_rf(fe_build)
  FileUtils.mkdir_p(out)
  run!("cp", "-rs", edg, fe_build)
  %w[bin/cpfe bin/eccp environment.sh].each { |p| FileUtils.rm_f(File.join(fe_build, p)) }
  FileUtils.ln_s(File.realpath(front_end), File.join(fe_build, "bin/cpfe"))
  # sed "s|A|B|" (the first match on each line)
  sed_first = lambda do |src, dst, from, to|
    re = Regexp.new(Regexp.escape(from))
    File.write(dst, File.read(src).lines.map { |l| l.sub(re, to) }.join)
  end
  sed_first.call(File.join(edg, "environment.sh"), File.join(fe_build, "environment.sh"),
                 "#{edg}/bin/cpfe", "#{fe_build}/bin/cpfe")
  sed_first.call(File.join(edg, "bin/eccp"), File.join(fe_build, "bin/eccp"),
                 "#{edg}/environment.sh", "#{fe_build}/environment.sh")
  run!("chmod", "+x", File.join(fe_build, "bin/eccp"))
  puts "selfhost-cpfe: front end #{front_end} (EDG tree #{fe_build})"
end

# The source list is the cpfe link line of EDG's cmake build (ninja knows it).
ninja_out = IO.popen(["ninja", "-C", edg, "-t", "commands", "bin/cpfe"], &:read)
ninja_rc = $?.exitstatus || 127
cands = ninja_out.lines.flat_map { |l| l.scan(/ -c [^ ]*\.c$/) }
grep_o_rc = cands.empty? ? 1 : 0
srcs = cands.map { |c| c.sub(/\A -c /, "") }.uniq.sort
kept = srcs.reject { |s| s.match?(%r{/mk_errinfo\.c\z}) }
grep_v_rc = kept.empty? ? 1 : 0
# set -o pipefail: the rightmost failing stage of the pipeline is its status; an empty list ends the script there
pipe_rc = [ninja_rc, grep_o_rc, 0, 0, grep_v_rc].reverse.find { |x| x != 0 } || 0
exit pipe_rc unless pipe_rc.zero?
srcs = kept
puts "selfhost-cpfe: #{srcs.size} sources"

FileUtils.rm_rf(File.join(out, "src"))
FileUtils.rm_rf(File.join(out, "obj"))
FileUtils.rm_rf(File.join(out, "run"))
%w[src obj run].each { |d| FileUtils.mkdir_p(File.join(out, d)) }
names = []
srcs.each do |f|
  b = File.basename(f, ".c")
  FileUtils.ln_s(f, File.join(out, "src", "#{b}.cpp"))
  names << b
end

# One compile per source; each runs in its own directory (cpfe writes <stem>.ti into its working directory).
def compile_one(name, root, out, edg, base, fe_build)
  dir = File.join(out, "run", name)
  FileUtils.mkdir_p(dir)
  argv = [File.join(root, "nfcxx"), "-c",
          "-DBACK_END_IS_C_GEN_BE=1", "-DCOMPILE_MULTIPLE_TRANSLATION_UNITS=1",
          "-DDO_IL_LOWERING=1", "-DLOWER_FIXED_POINT=1", "-DLOWER_IFUNC=1", "-DNEED_IL_DISPLAY=1",
          "-DRECORD_BACKING_EXPRS_WITH_IL_LOWERING=1", "-DUSE_CMAKE_DEFINES",
          "-I#{edg}/src/includes", "-I#{File.join(root, '3rd/edg/src')}",
          "-o", File.join(out, "obj", "#{name}.o"), File.join(out, "src", "#{name}.cpp")]
  env = { "NFCXX_BACKEND" => "gcc", "EDG_BUILD" => fe_build, "EDG_BASE" => base }
  st = run_status(env, *argv, chdir: dir, out: File.join(out, "run", "#{name}.log"), err: [:child, :out])
  return true if st.zero?

  warn "selfhost-cpfe: compile failed: #{name} (see #{out}/run/#{name}.log)"
  false
end

queue = Queue.new
names.each { |n| queue << n }
failed = 0
mutex = Mutex.new
workers = jobs <= 0 ? names.size : [jobs, 1].max
threads = Array.new([workers, names.size].min) do
  Thread.new do
    until queue.empty?
      name = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      ok = compile_one(name, root, out, edg, base, fe_build)
      mutex.synchronize { failed += 1 } unless ok
    end
  end
end
threads.each(&:join)
# xargs exits 123 when a compile failed; the pipeline's status ends the script
exit 123 unless failed.zero?
puts "selfhost-cpfe: #{Dir.glob(File.join(out, 'obj', '*.o')).size} objects"

# The link: nfcxx passes the objects to eccp, which links libC.a; qbe-cc adds libnfcxxld.a and -lstdc++.
# The x86-64 runtime (NFCXX_LDRT_X86=1, scripts/pathb-ldrt.rb) goes first: the front end folds out-of-range float-to-integer
# conversions the way x86-64 gcc does, where user programs keep the trap. Its archive has the same symbols as the default
# one, so the default archive is not pulled for them.
objs = names.map { |name| File.join(out, "obj", "#{name}.o") }
begin
  x86rt = IO.popen([{ "NFCXX_LDRT_X86" => "1" }, File.join(root, "scripts/pathb-ldrt.rb")], &:read)
rescue SystemCallError
  exit 127
end
exit($?.exitstatus || 1) unless $?.success?
x86rt = x86rt.sub(/\n+\z/, "")

st = run_status({ "NFCXX_BACKEND" => "gcc", "EDG_BUILD" => fe_build, "EDG_BASE" => base },
                File.join(root, "nfcxx"), *objs, x86rt, "-o", File.join(out, "cpfe"),
                chdir: File.join(out, "run"), out: File.join(out, "link.log"), err: [:child, :out])
unless st.zero?
  warn "selfhost-cpfe: link failed (see #{out}/link.log)"
  exit 1
end
puts "selfhost-cpfe: built #{out}/cpfe"
