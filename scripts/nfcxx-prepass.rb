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
#   file PATH          PATH is a regular file (the bash's [ -f PATH ]), keyed by the string the bash tests
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
# Exit status: 0 when the pre-pass completes (the main compile is not planned here), otherwise the bash's status (2 for
# its usage errors; the status of the failing step for cppfront and the SYCL passes); 3 for an argument or fact that is
# not covered by this port: the reason goes to stderr, nothing to stdout.
#
# Not covered (exit 3): every option parse_args does not list (-E, -M*, -x, -fsyntax-only, --emit-c, --trace, --cache,
# -fsanitize, and the rest), .cu and .c inputs, - (stdin), any other input extension, -o without a file, and a fact the
# plan needs that is missing. The driver's setup before the pre-pass (the host probes, the wrappers, the cuda-rewrite
# tool) is assumed to succeed. The port does not read the driver's text: its rules are restated here and tested by run.sh.
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
    @files = facts[:file]
    @execs = facts[:exec]
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
    @files.include?(path)
  end

  def exec?(path)
    @execs.include?(path)
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

# parse_args: the driver's option loop, for the options this port covers. Returns the state the pre-pass reads.
def parse_args(argv)
  st = { compile_only: false, out: "a.out", outset: false, srcs: [], cpp2: [], ncpp: 0, nobj: 0 }
  i = 0
  while i < argv.size
    a = argv[i]
    case a
    when "-c" then st[:compile_only] = true
    when "-o"
      raise Unported, "-o without a file" if i + 1 >= argv.size
      st[:out] = argv[i + 1]
      st[:outset] = true
      i += 1
    when "-I", "-D", "-U"
      raise Stop.new(2, "nfcxx: #{a} needs an argument") if i + 1 >= argv.size
      i += 1
    when /\A-[IDU]./ then nil
    when /\A-std=(c\+\+|gnu\+\+)\d+\z/ then nil
    when /\A-W/, "-w", "-pipe", /\A-O[0-3sg]?\z/, /\A-g\d?\z/, "-fPIC", "-fpic", "-pthread",
         "-fexceptions", "-fwrapv", "-fno-strict-aliasing"
      nil
    when /\A-l./ then nil
    when /\.o\z/
      st[:nobj] += 1
    when /\.cpp2\z/
      st[:cpp2] << a
      st[:srcs] << a
      st[:ncpp] += 1
    when /\.(cc|cpp|cxx|C|ii)\z/
      st[:srcs] << a
      st[:ncpp] += 1
    else
      raise Unported, "argument #{a.inspect} is not covered"
    end
    i += 1
  end
  st
end

# sycl_kernel_headers ARG...: a -I directory of the arguments holds sycl/detail/kernel_desc.hpp (the bash's loop, as is)
def sycl_kernel_headers?(plan, argv)
  prev = nil
  argv.each do |a|
    d = nil
    d = a[2..] if a.start_with?("-I") && a.length > 2
    d = a if prev == "-I"
    prev = a
    return true if d && !d.empty? && plan.file?("#{d}/sycl/detail/kernel_desc.hpp")
  end
  false
end

# grep -Eq '#[[:space:]]*include[[:space:]]*[<"]sycl/' FILE (line by line, as grep matches)
def sycl_include?(path)
  return false unless File.file?(path)
  File.foreach(path).any? { |l| l =~ /#[[:space:]]*include[[:space:]]*[<"]sycl\// }
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

# cpp2_prepare: each .cpp2 input is translated by cppfront into the cache (-c) or a temporary directory
def cpp2_path(plan, st)
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

# run: the pre-pass for ARGV. Returns the bash's exit status; raises Stop or Unported.
def run_prepass(plan, argv)
  st = parse_args(argv)
  if st[:ncpp] + st[:nobj] == 0
    raise Stop.new(2, "nfcxx: no input files")
  end
  if st[:compile_only] && st[:ncpp] == 1 && st[:nobj] == 0 && !plan.env("NFCXX_SYCL_PASS") &&
     sycl_kernel_headers?(plan, argv) && sycl_include?(st[:srcs][0])
    sycl_path(plan, st, argv)
    return 0
  end
  cpp2_path(plan, st)
  0
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
      status = run_prepass(plan, argv)
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
