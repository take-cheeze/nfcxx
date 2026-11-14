#!/usr/bin/env ruby
# nfcxx-prepass.rb: plan printer for the two pre-passes of the nfcxx driver that run before the main compile.
#   1. cppfront for .cpp2 inputs (nfcxx: cpp2_prepare, docs/notes/cpp2.md)
#   2. the SYCL two-pass build of a -c compile of one source that includes <sycl/...> (nfcxx: sycl_kernel_headers
#      and the block after it, docs/notes/sycl-kernel-builtins.md)
#
#   ruby scripts/nfcxx-prepass.rb --facts=FILE --root=DIR ARG...
#
# ARG... is the driver's argument list. The output is one line per external command the pre-pass runs, in the bash's
# order, then "STATUS N" (the bash's exit status). Line kinds:
#   RUN [cwd=DIR] CMD ARGS      an external command (cppfront, the integration-header script, mkdir -p)
#   EXEC [VAR=V ...] CMD ARGS   a nested run of the driver (the two SYCL passes); its own output is not planned
#   CAT FILE                    cat FILE to stderr (the SYCL pass-1 log, when no kernels were recorded)
#   WRITE FILE                  a file the pre-pass writes; "| LINE" lines after it are its content when the pre-pass
#                               writes it from shell text (the wrapper). Files written by a command are not listed with content.
# The text the bash prints to stderr and its exit status are printed the same way: "nfcxx: ..." on stderr, STATUS N.
#
# Facts (--facts=FILE, one fact per line; the test writes them from the sandbox it builds):
#   file PATH          PATH is a regular file (the bash's [ -f PATH ]); the names are compared with their empty and . parts
#                      dropped, as the file system sees them (a doubled slash names the same file)
#   exec PATH          PATH is executable (the bash's [ -x PATH ])
#   env NAME VALUE     an environment variable the bash sees (an empty value counts as unset, as ${NAME:-...} does)
#   cppfront-rc N      the exit status of every cppfront run
#   sycl-dump N        the number of kernel records pass 1 writes (0: the dump file is empty)
#   sycl-header-rc N   the exit status of scripts/sycl-integration-header.sh
#   sycl-pass2-rc N    the exit status of the second SYCL pass
# A fact the plan needs and the file does not give makes the plan unported. A file is considered present only when it
# is listed as a file fact (the facts list what exists). The input sources are read from the disk, relative to the
# working directory: their existence, their directory, their full path (realpath) and whether they include <sycl/...>.
#
# The option loop is the driver's, in the driver's case order: a pattern earlier in the loop wins (so -Ifoo.c is a .c
# input, and -foo.o an object). Options the loop only passes on (-fPIC, -MD, -Wl,..., the back-end flags) change nothing
# here. The driver's setup before the loop is modelled too: -fsyntax-only (the driver runs itself again: the port runs
# the same plan for that run), the wrappers (--cuda-driver= is taken out; a --bundle-* option is not covered), and
# NFCXX_CACHE_REMOTE. The host probes and the cuda-rewrite tool are assumed to succeed.
#
# Exit status: 0 when the pre-pass completes (the main compile is not planned here), otherwise the bash's status (2 for
# its usage errors; the status of the failing step for cppfront and the SYCL passes); 3 for an argument or fact that is
# not covered by this port: the reason goes to stderr, nothing to stdout.
#
# Not covered (exit 3): .cu inputs (their device pre-pass belongs to the CUDA plan), a --bundle-libs link (the bundle
# wrapper then runs nfcbundle on the output), a link that names libcuda with a mode other than libcuda (the driver shim),
# a -fsyntax-only compile of a .cpp2 input without -E (its cache key is of a temporary object path), a -I directory
# with a .. part (the test follows the file system's links), an empty -o name, --trace/--time-log whose file cannot be
# written here, and a fact the plan needs that is missing.
#
# Bundle options (scripts/bundle-wrap.sh): without --bundle-libs they are a usage error; with it, a -c or -E command
# runs the driver again without them, and the pre-pass of that run is the plan.
#
# An option whose value is the next argument (-o, -x, -MF, -MT, -MQ, -include, -isystem) with no next argument is an
# unbound variable under the driver's set -u: the shell exits with status 1 before anything is run.
require 'digest/sha1'

class Unported < StandardError; end

class Stop < StandardError
  attr_reader :status
  def initialize(status, msg = nil)
    @status = status
    super(msg)
  end
end

class Plan
  attr_reader :lines

  def initialize(facts, root, cwd)
    @files = facts[:file].map { |f| canon_path(f) }
    @execs = facts[:exec].map { |f| canon_path(f) }
    @env = facts[:env]
    @ints = facts[:ints]
    @root = root
    @cwd = cwd
    @lines = []
  end

  def emit(line)
    @lines << line
  end

  def file?(path)
    @files.include?(canon_path(path))
  end

  def exec?(path)
    @execs.include?(canon_path(path))
  end

  # ${NAME:-...}: an empty variable is unset
  def env(name)
    v = @env[name]
    (v.nil? || v.empty?) ? nil : v
  end

  def int_fact(name)
    v = @ints[name]
    raise Unported, "fact #{name} is not given" if v.nil?
    v
  end

  def root
    @root
  end

  def cwd
    @cwd
  end
end

# The path the file system finds for PATH, as far as the names go: empty and . parts are dropped (a//b and a/./b name a/b
# on Linux, whether or not a is a directory). A .. part is kept: what it names depends on the links, so it is not decided here.
def canon_path(path)
  parts = path.split("/").reject { |c| c.empty? || c == "." }
  (path.start_with?("/") ? "/" : "") + parts.join("/")
end

# The bash case pattern PAT matches A (a leading dot is matched too, as the shell's * does)
def glob?(a, pat)
  File.fnmatch?(pat, a, File::FNM_DOTMATCH)
end

# A -o, -x, -include, ... option takes the next argument; the bash reads $2, which is unbound at the end (set -u: the
# shell exits with status 1, and nothing has been run yet: the option loop is first)
def value_of!(argv, i)
  raise Stop.new(1, "nfcxx-prepass: #{argv[i]}: unbound variable $2 (no value)") if i + 1 >= argv.size
  argv[i + 1]
end

# onoff FLAG VALUE (the driver's): on|1 and off|0 are the values. Run in $(...) and assigned, so its exit 2 ends the driver.
def onoff!(flag, val)
  return if %w[on 1 off 0].include?(val)
  raise Stop.new(2, "nfcxx: #{flag} takes on or off (got '#{val}')")
end

# The file a trace or time log writes must be in an existing directory and not be a directory (abs_path, then '>')
def writable_here?(path)
  File.directory?(File.dirname(path)) && !File.directory?(path)
end

# The driver's --cuda-driver handling (scripts/cuda-driver-wrap.sh), before the option loop: the option is taken out,
# and its mode is checked. A libcuda link that the wrapper replaces (the shim) is not covered.
def cuda_driver_prelude(plan, argv)
  mode = plan.env("NFCXX_CUDA_DRIVER") || "auto"
  found = false
  out = []
  argv.each do |a|
    if a.start_with?("--cuda-driver=")
      mode = a.delete_prefix("--cuda-driver=")
    else
      if %w[-lcuda -l:libcuda.so -l:libcuda.so.1].include?(a) || glob?(a, "*/libcuda.so") || glob?(a, "*/libcuda.so.1")
        found = true
      end
      out << a
    end
  end
  unless %w[auto cudart libcuda].include?(mode)
    raise Stop.new(2, "nfcxx: --cuda-driver=#{mode}: auto, cudart or libcuda")
  end
  raise Unported, "a link that names libcuda is replaced by the driver shim" if found && mode != "libcuda"
  out
end

# The option loop (nfcxx, the while loop over the arguments), for the parts that can change the pre-pass. The case
# arms are in the driver's order; the first one that matches wins. Returns the state the pre-pass reads.
def parse_args(argv)
  st = { compile_only: false, out: "a.out", outset: false, srcs: [], cpp2: [], ncpp: 0, nobj: 0, ncfiles: 0,
         stdin: false, preprocess: false, emit_c: false, emit_hip: false, trace: nil, time_log: nil }
  i = 0
  while i < argv.size
    a = argv[i]
    case
    when a == "--emit-c" then st[:emit_c] = true
    when a == "--emit-hip" then st[:emit_hip] = true
    when glob?(a, "--backend=*"), glob?(a, "--ir-opt=*"), a == "--eh-unwind", a == "--no-eh-unwind",
         a == "--no-eh-shim", glob?(a, "--cache=*"), glob?(a, "--cache-log=*"), a == "--keep-intermediates"
      nil
    when glob?(a, "--time-log=*") then st[:time_log] = a.delete_prefix("--time-log=")
    when glob?(a, "--instantiate=*") then nil
    when glob?(a, "--promote-slots=*") then onoff!("--promote-slots", a.delete_prefix("--promote-slots="))
    when glob?(a, "--unroll=*") then onoff!("--unroll", a.delete_prefix("--unroll="))
    when glob?(a, "--struct-slots=*") then onoff!("--struct-slots", a.delete_prefix("--struct-slots="))
    when glob?(a, "--pathb-c=*"), glob?(a, "-fuse-ld=*"), a == "--obfuscate-kernels" then nil
    when a == "-fsanitize=address", a == "-fsafe-pointers", a == "-fno-safe-pointers", a == "-fno-sanitize=address"
      nil
    when glob?(a, "-fsanitize=*"), glob?(a, "-fsanitize-*")
      raise Stop.new(2, "nfcxx: #{a} is not supported (only -fsanitize=address; docs/notes/asan.md)")
    when a == "-fno-omit-frame-pointer", a == "-fomit-frame-pointer" then nil
    when glob?(a, "--dialect=*"), glob?(a, "--gnu-version=*"), a == "--freestanding", a == "--cosmo",
         glob?(a, "--target=*"), glob?(a, "--module-dir=*")
      nil
    when glob?(a, "--trace=*") then st[:trace] = a.delete_prefix("--trace=")
    when a == "-shared", a == "-fPIC", a == "-fpic", a == "-rdynamic" then nil
    when a == "-c" then st[:compile_only] = true
    when a == "-o"
      out = value_of!(argv, i)
      raise Unported, "-o with an empty name" if out.empty?
      st[:out] = out
      st[:outset] = true
      i += 1
    when glob?(a, "-std=c++*"), glob?(a, "-std=gnu++*") then nil
    when a == "-E" then st[:preprocess] = true
    when a == "-P" then nil
    when a == "-x" then value_of!(argv, i); i += 1
    when a == "-" then st[:stdin] = true
    when a == "-pthread", a == "-fexceptions", a == "-fwrapv", a == "-fno-strict-aliasing", a == "-fno-sanitize=all",
         a == "-pipe"
      nil
    when glob?(a, "-fno-sanitize=*")
      raise Stop.new(2, "nfcxx: #{a} is not supported (only -fsanitize=undefined and its checks, docs/notes/ubsan.md)")
    when glob?(a, "-fvisibility=*"), a == "-fvisibility-inlines-hidden", a == "-fPIE", a == "-fpie", a == "-pie"
      nil
    when glob?(a, "-Wl,*"), glob?(a, "-l?*"), a == "-Wno-narrowing", glob?(a, "-W*"), a == "-w", glob?(a, "-m*")
      nil
    when a == "-MD", a == "-MMD", a == "-MP" then nil
    when a == "-MF", a == "-MT", a == "-MQ" then value_of!(argv, i); i += 1
    when a == "-include", a == "-isystem" then value_of!(argv, i); i += 1
    when glob?(a, "-isystem?*") then nil
    when glob?(a, "*.c") then st[:ncfiles] += 1
    when glob?(a, "-I?*"), glob?(a, "-D?*"), glob?(a, "-U?*") then nil
    when a == "-I", a == "-D", a == "-U"
      raise Stop.new(2, "nfcxx: #{a} needs an argument") if i + 1 >= argv.size
      i += 1
    when glob?(a, "*.o") then st[:nobj] += 1
    when glob?(a, "-*"), glob?(a, "*.a"), glob?(a, "*.so") then nil
    when glob?(a, "*.cu") then raise Unported, ".cu input: its device pre-pass belongs to the CUDA plan"
    when glob?(a, "*.cpp2")
      st[:cpp2] << a
      st[:srcs] << a
      st[:ncpp] += 1
    else
      st[:srcs] << a
      st[:ncpp] += 1
    end
    i += 1
  end
  st
end

# sycl_kernel_headers ARG...: a -I directory of the arguments holds sycl/detail/kernel_desc.hpp (the bash's loop, as is).
# The file test is the bash's [ -f ]: a doubled or trailing slash and a . part name the same file (canon_path), so they are
# decided here; a .. part is not (Unported).
def sycl_kernel_headers?(plan, argv)
  prev = nil
  argv.each do |a|
    d = nil
    d = a[2..] if a.start_with?("-I") && a.length > 2
    d = a if prev == "-I"
    prev = a
    next if d.nil? || d.empty?
    raise Unported, "-I directory #{d.inspect} has a .. part (the file test follows the links)" if d.split("/").include?("..")
    return true if plan.file?("#{d}/sycl/detail/kernel_desc.hpp")
  end
  false
end

# grep -Eq '#[[:space:]]*include[[:space:]]*[<"]sycl/' FILE (line by line, as grep matches; bytes, as grep reads them)
def sycl_include?(path)
  return false unless File.file?(path)
  File.open(path, "rb") { |f| f.each_line.any? { |l| l =~ /#[[:space:]]*include[[:space:]]*[<"]sycl\// } }
rescue StandardError
  false
end

# realpath FILE (GNU, default mode): every component but the last must exist; the last may be missing
def realpath_but_last(path)
  File.join(File.realpath(File.dirname(path)), File.basename(path))
end

# ${FILE%.*}: the name without its last extension (the last dot, as the shell's shortest suffix match)
def strip_ext(path)
  i = path.rindex(".")
  i ? path[0...i] : path
end

WRAPPER_TMP = "<tmp>"

def sycl_path(plan, st, argv)
  src = st[:srcs][0]
  sy_src = File.realpath(src)   # the grep above found the file, so every component exists
  dump = "#{WRAPPER_TMP}/dump"
  plan.emit "EXEC NFCXX_SYCL_PASS=1 NFCXX_SYCL_DUMP=#{dump} #{plan.root}/nfcxx #{argv.join(' ')}"
  n = plan.int_fact("sycl-dump")
  if n == 0
    plan.emit "CAT #{WRAPPER_TMP}/pass1.log"
    raise Stop.new(2, "nfcxx: the SYCL pre-pass recorded no kernels")
  end
  plan.emit "RUN #{plan.root}/scripts/sycl-integration-header.sh #{dump}"
  plan.emit "WRITE #{WRAPPER_TMP}/integration.hpp"
  raise Stop.new(2) unless plan.int_fact("sycl-header-rc") == 0
  wrapper = [
    "#include <sycl/sycl.hpp>",
    "#include \"#{WRAPPER_TMP}/integration.hpp\"",
    "#include \"#{sy_src}\"",
  ]
  plan.emit "WRITE #{WRAPPER_TMP}/wrapper.cpp"
  wrapper.each { |l| plan.emit "| #{l}" }
  sy_args = argv.map { |a| a == src ? "#{WRAPPER_TMP}/wrapper.cpp" : a }
  sy_args += ["-o", "#{File.basename(strip_ext(sy_src))}.o"] unless st[:outset]
  plan.emit "EXEC NFCXX_SYCL_PASS=1 #{plan.root}/nfcxx -D__SYCL_UNNAMED_LAMBDA__=1 #{sy_args.join(' ')}"
  rc = plan.int_fact("sycl-pass2-rc")
  raise Stop.new(rc) unless rc == 0
end

# cpp2_prepare: each .cpp2 input is translated by cppfront into the cache (-c) or a temporary directory.
# tmp_obj: the object is a temporary path of a -fsyntax-only run, so the cache key is not known here.
def cpp2_path(plan, st, tmp_obj)
  return if st[:cpp2].empty?
  root = plan.root
  cppfront_src = plan.env("CPPFRONT_SRC") || "#{root}/build/cppfront-src"
  unless plan.exec?("#{root}/build/cppfront")
    raise Stop.new(2, "nfcxx: cppfront is not built; run scripts/setup-cppfront.sh (docs/notes/cpp2.md)")
  end
  unless plan.file?("#{cppfront_src}/include/cpp2util.h")
    raise Stop.new(2, "nfcxx: no cpp2util.h under #{cppfront_src}; run scripts/setup-cppfront.sh")
  end
  dir =
    if st[:compile_only]
      raise Unported, "-fsyntax-only of a .cpp2 input: its cache key is of a temporary object" if tmp_obj
      obj = st[:outset] ? st[:out] : "#{File.basename(st[:cpp2][0], '.cpp2')}.o"
      key = Digest::SHA1.hexdigest(File.expand_path(obj, plan.cwd) + "\n")[0, 16]
      cache = plan.env("NFCXX_CU_CACHE") ||
              "#{plan.env("XDG_CACHE_HOME") || "#{plan.env("HOME") || "/tmp"}/.cache"}/nfcxx"
      d = "#{cache}/cpp2/#{key}"
      plan.emit "RUN mkdir -p #{d}"
      d
    else
      WRAPPER_TMP
    end
  st[:cpp2].each do |src|
    raise Stop.new(1, "realpath: #{File.dirname(src)}: No such file or directory") unless File.directory?(File.dirname(src))
    copy = "#{dir}/#{File.basename(src, '.cpp2')}.cpp"
    abs = realpath_but_last(src)
    plan.emit "RUN cwd=#{WRAPPER_TMP} #{root}/build/cppfront -q -o #{copy} #{abs}"
    rc = plan.int_fact("cppfront-rc")
    raise Stop.new(rc) unless rc == 0
  end
end

# bundle_wrap (scripts/bundle-wrap.sh, sourced before the option loop): the --bundle-* options are checked in order, then
# the driver runs again without them. A link is run and then nfcbundle rewrites the output: not covered.
NO_LINK_OPTIONS = %w[-c -E -S -M -MM -fsyntax-only --emit-c].freeze
def bundle_wrap(plan, argv, tmp_obj)
  return nil unless (" #{argv.join(' ')} ").include?(" --bundle-")
  on = false
  link = true
  args = []
  argv.each do |a|
    case
    when a == "--bundle-libs" then on = true
    when glob?(a, "--bundle-exclude=*"), glob?(a, "--bundle-only=*"), glob?(a, "--bundle-add=*"),
         glob?(a, "--bundle-stubs=*"), glob?(a, "--bundle-runpath=*"), glob?(a, "--bundle-rpath=*")
      nil
    when glob?(a, "--bundle-*")
      raise Stop.new(2, "nfcxx: unknown option #{a} (--bundle-libs, --bundle-exclude=, --bundle-only=, --bundle-add=, " \
                        "--bundle-stubs=, --bundle-runpath=, --bundle-rpath=)")
    else
      args << a
      link = false if NO_LINK_OPTIONS.include?(a)
    end
  end
  raise Stop.new(2, "nfcxx: the --bundle-* options need --bundle-libs") unless on
  raise Unported, "--bundle-libs on a link: nfcbundle rewrites the output" if link
  # the driver runs again on ARGS (its own pre-pass is the plan); the wrapper then exits 0
  run_driver(plan, args, tmp_obj)
  0
end

# run_driver: the driver's setup and pre-pass for ARGV. Returns the bash's exit status; raises Stop or Unported.
def run_driver(plan, argv, tmp_obj)
  return run_fso(plan, argv, tmp_obj) if argv.include?("-fsyntax-only")
  bundled = bundle_wrap(plan, argv, tmp_obj)
  return bundled unless bundled.nil?
  argv = cuda_driver_prelude(plan, argv)
  cache_remote = plan.env("NFCXX_CACHE_REMOTE")
  raise Stop.new(2, "nfcxx: NFCXX_CACHE_REMOTE takes gha (got '#{cache_remote}')") if cache_remote && cache_remote != "gha"
  st = parse_args(argv)
  if st[:ncpp] + st[:nobj] + st[:ncfiles] + (st[:stdin] ? 1 : 0) == 0
    raise Stop.new(2, "nfcxx: no input files")
  end
  # the .cu inputs are not covered, so none is here
  raise Stop.new(2, "nfcxx: --emit-hip takes one .cu file") if st[:emit_hip]
  if st[:compile_only] && st[:ncpp] == 1 && st[:nobj] == 0 && st[:ncfiles] == 0 && !st[:preprocess] && !st[:emit_c] &&
     !plan.env("NFCXX_SYCL_PASS") && sycl_kernel_headers?(plan, argv) && sycl_include?(st[:srcs][0])
    sycl_path(plan, st, argv)
    return 0
  end
  # the trace (--trace or NFCXX_TRACE) is opened here, before the translation; its file is written at once
  trace = st[:trace].nil? ? plan.env("NFCXX_TRACE") : st[:trace]
  time_log = st[:time_log].nil? ? plan.env("NFCXX_TIME_LOG") : st[:time_log]
  unless trace.to_s.empty?
    raise Unported, "--trace file #{trace}: its directory is not checked here" unless writable_here?(trace)
    raise Unported, "--time-log file #{time_log}: its directory is not checked here" if time_log && !writable_here?(time_log)
  end
  cpp2_path(plan, st, tmp_obj)
  0   # the checks after the pre-pass (a stdin source without -E, -x) belong to the main compile: not planned here
end

# The -fsyntax-only block: the driver runs itself again without the option (a -E run is an exec of the same arguments; a
# type check is a -c run with a temporary object, which the SYCL path names but the cpp2 cache key does not allow).
def run_fso(plan, argv, tmp_obj)
  rest = argv.reject { |b| b == "-fsyntax-only" }
  return run_driver(plan, rest, false) if rest.include?("-E")
  if rest.include?("-o")
    new_args = []
    skip = false
    rest.each do |b|
      if skip
        skip = false
        new_args << "#{WRAPPER_TMP}/x.o"
        next
      end
      skip = true if b == "-o"
      new_args << b
    end
    run_driver(plan, ["-c"] + new_args, true)
  else
    run_driver(plan, ["-c"] + rest + ["-o", "#{WRAPPER_TMP}/x.o"], true)
  end
end

def read_facts(path)
  facts = { file: [], exec: [], env: {}, ints: {} }
  File.foreach(path) do |line|
    f = line.split(" ")
    next if f.empty?
    case f[0]
    when "file" then facts[:file] << f[1]
    when "exec" then facts[:exec] << f[1]
    when "env" then facts[:env][f[1]] = f[2] || ""
    when "cppfront-rc", "sycl-dump", "sycl-header-rc", "sycl-pass2-rc"
      facts[:ints][f[0]] = Integer(f[1])
    else
      raise Unported, "unknown fact #{f[0]}"
    end
  end
  facts
end

if $PROGRAM_NAME == __FILE__
  facts_path = nil
  root = nil
  argv = ARGV.dup
  while argv.first&.start_with?("--facts=", "--root=")
    o = argv.shift
    if o.start_with?("--facts=") then facts_path = o.delete_prefix("--facts=")
    else root = o.delete_prefix("--root=")
    end
  end
  abort "nfcxx-prepass: --facts= and --root= are needed" unless facts_path && root
  begin
    plan = Plan.new(read_facts(facts_path), root, Dir.pwd)
    status = 0
    begin
      status = run_driver(plan, argv, false)
    rescue Stop => e
      $stderr.puts e.message if e.message
      status = e.status
    end
    plan.lines.each { |l| puts l }
    puts "STATUS #{status}"
    exit status
  rescue Unported => e
    $stderr.puts "nfcxx-prepass: unported: #{e.message}"
    exit 3
  end
end
