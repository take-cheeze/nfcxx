#!/usr/bin/env ruby
# nfcxx's --freestanding and --emit-c / --emit-hip paths, ported from the bash in nfcxx: the argument checks that come
# before the back end is chosen, the --target checks, the include and GNU-version setup of the front end, the EDG front
# end run that prints the generated C (cpfe with --gen_c_file_name), and the rewriter exec of --emit-hip.
#
#   ruby scripts/nfcxx-freestanding.rb --facts=FILE ARG...
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the exit status the bash ends with):
#   ENV NAME=VALUE         a variable the bash exports for the program that follows (EDG_CPFE_DEFAULT_OPTIONS)
#   RUN PROGRAM ARG...     a program the driver runs (ROOT/build/edg/bin/cpfe); its output is not part of the plan
#   EXEC PROGRAM ARG...    the program replaces nfcxx (--emit-hip: ROOT/build/cuda-rewrite). No STATUS line: the exit
#                          status is the program's.
# ROOT stands for the repository, WORK for the working directory, TMP for a temporary directory (mktemp -d).
#
# A refusal the bash makes before it runs anything (status 2: no input files, a bad --dialect, --target without
# --freestanding or --emit-c, an unknown --target, --emit-hip without one .cu, C sources with --emit-c, a module
# with --emit-c) prints only "STATUS 2". Any argument list outside the paths above, or one whose bash run would go on
# into the compile and link (the backend, the EDG driver, a link), exits 3 with "unported: ..." on stderr and prints
# nothing on stdout.
#
# FILE holds the facts the bash reads from the machine (tests/nfcxx-freestanding/run.sh writes it):
#   uname NAME              uname -s (the port handles Linux only)
#   cxx-clang 0|1           the host C++ compiler (g++) is clang
#   gnu-dump VERSION        g++ -dumpfullversion (empty or absent: none)
#   host-sys DIR            a directory of the host C++ library, in host_sys_includes' order
#   target-table NAME       EDG's lib_NAME table exists (--target=NAME)
#   eh-tls 1                ${EDG}/../eh-tls exists
#   module PATH             PATH declares or imports a C++ module
#   exists PATH             PATH (relative to WORK) is an existing directory (abs_path of an -I with a slash)
#
# Assumed, not read: the environment (NFCXX_* variables are not set, as the harness runs the bash with none), the
# built repository tools (ensure_tool finds build/cuda-rewrite and build/edg/bin/eccp fresh), and the EDG base
# directory, which the front end runs in.

class Unported < StandardError
end

# the bash ends with this status (after a refusal it makes before it runs anything)
class Ends < StandardError
  attr_reader :status

  def initialize(status)
    super("status #{status}")
    @status = status
  end
end

ROOT = "ROOT".freeze
WORK = "WORK".freeze
TMP = "TMP".freeze
EDG_BIN = "ROOT/build/edg/bin".freeze
EDG_BASE = "ROOT/build/edg-base".freeze
# the targets for which the driver passes --unsigned_chars (plain char is unsigned on their ABIs)
UNSIGNED_CHAR_TARGETS = %w[linux_aarch64 linux_armv7 linux_riscv32 linux_riscv64].freeze

class Facts
  def initialize(path)
    @single = {}
    @lists = Hash.new { |h, k| h[k] = [] }
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")
      key, value = line.split(" ", 2)
      value ||= ""
      @single[key] ||= value
      @lists[key] << value
    end
  end

  def value(key)
    @single[key]
  end

  def list(key)
    @lists[key]
  end

  def flag?(key)
    @single[key] == "1"
  end

  def exists?(path)
    list("exists").include?(path)
  end
end

# host_gnu_version: major*10000 + minor*100 + patch from g++ -dumpfullversion; 150000 for a clang host without it
def host_gnu_version(facts)
  ver = facts.value("gnu-dump").to_s
  if ver.empty?
    return facts.flag?("cxx-clang") ? "150000" : nil
  end
  maj, min, pat = ver.split(".")
  (maj.to_i * 10000 + min.to_i * 100 + pat.to_i).to_s
end

# host_clang_version: the --clang_version value of the host clang (clang 21 is capped at 200000), or nil
def host_clang_version(facts)
  facts.flag?("cxx-clang") ? "200000" : nil
end

# abs_path of an -I value as the bash makes it (abs_path, which needs no existing path): a value without a slash
# names WORK's entry; with a slash, its directory must exist
def abs_include(value, facts)
  if value.start_with?("/") || value.include?("..") || value.end_with?("/")
    raise Unported, "-I#{value}: an absolute or parent path"
  end
  if value.include?("/")
    dir = File.dirname(value)
    raise Unported, "-I#{value}: its directory is not a fact" unless facts.exists?(dir)
  end
  "#{WORK}/#{value}"
end

# the argument loop of nfcxx for the options in this port; anything else is unported
def parse(argv)
  o = { emit_c: false, emit_hip: false, fs: false, target: nil, gnu: nil, dialect: nil, std: "--c++23",
        cflags: [], user_inc: [], srcs: [], cu: [], cfiles: [], diag: [] }
  i = 0
  while i < argv.size
    a = argv[i]
    case a
    when "--emit-c" then o[:emit_c] = true
    when "--emit-hip" then o[:emit_hip] = true
    when "--freestanding" then o[:fs] = true
    when /\A--target=(.*)\z/m then o[:target] = Regexp.last_match(1)
    when /\A--gnu-version=(.*)\z/m then o[:gnu] = Regexp.last_match(1)
    when /\A--dialect=(.*)\z/m then o[:dialect] = Regexp.last_match(1)
    when /\A--backend=/ then nil # the emit paths never read the backend (only the refused k1om and cosmo cases do)
    when /\A-std=c\+\+(.*)\z/m then o[:std] = "--c++#{Regexp.last_match(1)}"
    when /\A-std=gnu\+\+(.*)\z/m then o[:std] = "--c++#{Regexp.last_match(1)}"
    when "-o"
      raise Unported, "-o without a value" if i + 1 >= argv.size
      i += 1
    when "-I", "-D", "-U"
      raise Ends, 2 if i + 1 >= argv.size
      o[:cflags] << "#{a}#{argv[i + 1]}"
      o[:user_inc] << argv[i + 1] if a == "-I"
      i += 1
    when /\A-I./
      o[:cflags] << a
      o[:user_inc] << a[2..]
    when /\A-[DU]./ then o[:cflags] << a
    when "-Wno-narrowing" then o[:diag] << "--diag_warning=narrowing_conversion"
    when "-fexceptions", "-fwrapv", "-fno-strict-aliasing", "-pipe", "-w", "-fvisibility-inlines-hidden" then nil
    when /\A-W/, /\A-fvisibility=/ then nil
    when /\A-/ then raise Unported, "option #{a}"
    when /\.cu\z/ then o[:cu] << a
    when /\.c\z/ then o[:cfiles] << a
    when /\.cpp2\z/, /\.o\z/, /\.a\z/, /\.so\z/ then raise Unported, "input #{a}"
    else
      raise Unported, "input #{a} in a directory" if a.include?("/")
      o[:srcs] << a
    end
    i += 1
  end
  o
end

def plan(argv, facts)
  o = parse(argv)
  lines = []
  # the sources the bash counts: the .cu and .cpp inputs (ncpp), then the .c files apart
  sources = o[:cu] + o[:srcs]
  raise Ends, 2 if sources.empty? && o[:cfiles].empty?

  if o[:emit_hip]
    raise Ends, 2 unless o[:cu].size == 1
    lines << (["EXEC", "#{ROOT}/build/cuda-rewrite", "--hip"] + o[:cflags] + [o[:cu][0]]).join(" ")
    return lines
  end

  host_dialect = facts.flag?("cxx-clang") ? "clang" : "g++"
  dialect = o[:dialect] || host_dialect
  raise Ends, 2 unless %w[g++ clang].include?(dialect)

  modules = sources.any? { |s| facts.list("module").include?(s) }

  unless o[:emit_c]
    # The compile and link path (the backend is chosen after these checks): only its refusals are ported.
    if o[:target] && !o[:target].empty?
      raise Unported, "--target=linux_k1om" if o[:target] == "linux_k1om"
      raise Unported, "C++ modules without --emit-c" if modules
      raise Unported, "cu inputs before --target" unless o[:cu].empty?
      # both checks of --target end the run with status 2 before anything is run
      raise Ends, 2
    end
    raise Unported, "the compile and link path (no --emit-c, --emit-hip or --target)"
  end

  raise Unported, "cu inputs with --emit-c (the rewriter runs first)" unless o[:cu].empty?
  # the modules check: a module with --emit-c is refused (after the standard check, which also exits 2)
  raise Ends, 2 if modules

  # the front-end include and GNU-version setup
  if o[:fs]
    gnu = o[:gnu].nil? || o[:gnu].empty? ? "130000" : o[:gnu]
    sys_inc = []
  else
    sys_inc = facts.list("host-sys").map { |d| "--sys_include=#{d}" }
    gnu = o[:gnu].nil? || o[:gnu].empty? ? host_gnu_version(facts) : o[:gnu]
  end

  gnu_opts = []
  if dialect == "clang"
    cv = host_clang_version(facts)
    gnu_opts = ["--clang_version=#{cv}"] if cv
  elsif gnu && !gnu.empty?
    gnu_opts = ["--gnu_version=#{gnu}"]
  end

  target = o[:target]
  if target && !target.empty?
    raise Unported, "--target=linux_k1om" if target == "linux_k1om"
    raise Ends, 2 unless o[:fs]
    raise Ends, 2 unless facts.list("target-table").include?(target)
    gnu_opts += ["--target", target]
    gnu_opts << "--unsigned_chars" if UNSIGNED_CHAR_TARGETS.include?(target)
  end

  lines << "ENV EDG_CPFE_DEFAULT_OPTIONS=#{gnu_opts.join(' ')} " unless gnu_opts.empty?

  # the C sources do not go through the front end
  raise Ends, 2 unless o[:cfiles].empty?
  raise Unported, "host #{facts.value('uname')}" unless facts.value("uname") == "Linux"

  inc = if o[:fs]
          ["-I#{ROOT}/lib"]
        else
          sys_inc + ["--sys_include=#{EDG_BASE}/include"]
        end
  # each -I goes in front of the ones before it, as the bash prepends them in order
  o[:user_inc].each { |v| inc = ["-I#{abs_include(v, facts)}"] + inc }

  eh_tls = facts.flag?("eh-tls") ? ["--nfcxx_eh_thread_local"] : []
  args = ["-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", o[:std], "--#{dialect}"] + eh_tls + gnu_opts + o[:diag] + inc +
         ["--gen_c_file_name=#{TMP}/out.c", "#{WORK}/#{sources[0]}"]
  lines << (["RUN", "#{EDG_BIN}/cpfe"] + args).join(" ")
  lines << "STATUS 0"
  lines
end

def main(argv)
  facts_path = nil
  rest = []
  argv.each do |a|
    if a.start_with?("--facts=") then facts_path = a.delete_prefix("--facts=") else rest << a end
  end
  abort "usage: nfcxx-freestanding.rb --facts=FILE ARG..." unless facts_path
  facts = Facts.new(facts_path)
  begin
    out = plan(rest, facts)
    puts out
    0
  rescue Ends => e
    puts "STATUS #{e.status}"
    0
  rescue Unported => e
    warn "unported: #{e.message}"
    3
  end
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__
