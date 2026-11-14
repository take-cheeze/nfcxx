#!/usr/bin/env ruby
# nfcxx's Path B compile and link of hosted C++ sources, ported from the bash in nfcxx: the backend choice, the argument
# loop for the options of this slice, the scripts/pathb-cc calls of a -c compile and of a link (one per source, then the
# cc link with EDG's runtime, the EH shim and the long double helpers), and the fallback to the gcc backend that a
# default-selected Path B build takes when pathb-cc fails on a file. The argument loop is the one of nfcxx, for these
# options only (scripts/nfcxx-gcc-plan.rb has the same design for the gcc backend).
#
#   ruby scripts/nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG...
#
# --backend is the backend the driver is asked for: default (no --backend and no NFCXX_BACKEND: the driver picks Path B, and
# a file Path B fails on makes the driver build the program again with gcc), or pathb (--backend=pathb: the status of
# pathb-cc is the driver's status). gcc is scripts/nfcxx-gcc-plan.rb's, and is refused here. ARG... is the command line
# the bash gets, without --backend (an --backend in ARG... is refused).
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the status the bash ends with):
#   RUN PROGRAM ARG...     a program the driver runs: ROOT/scripts/pathb-cc (one C++ file to an object) or cc (the link)
#   EXEC PROGRAM ARG...    the driver is replaced (the gcc fallback: exec env NFCXX_BACKEND=gcc ROOT/nfcxx ARG...). The bash
#                          does not return from it, so no STATUS line follows; the status is the re-run's, not compared.
# ROOT stands for the repository and WORK for the working directory. The temporary object directory of a link is TMP
# (mktemp -d), its objects TMP/pN.o. A refusal the bash makes (status 2, a pathb-cc status under --backend=pathb) prints
# the lines before it, then its status. A construct the port does not cover exits 3 with "unported: ..." on stderr and
# prints nothing (nothing is guessed).
#
# Not covered (exit 3): the gcc backend; C sources (.c, with C++ sources or alone); .cu and .cpp2 inputs; modules; SYCL
# (a -I directory with the oneAPI kernel header); --freestanding, --cosmo, --target, --emit-c, --emit-hip, -shared, -E,
# -M and the -MD family, -fsyntax-only, -c with no C++ source, -fsanitize=address, -fsafe-pointers, the cache, the trace
# and time log options, CUDA options, --bundle-libs, --cuda-driver, --module-dir, --instantiate, and any other --option.
#
# FILE holds the facts the bash reads from the machine and from its helper scripts (tests/nfcxx-pathb/run.sh writes it):
#   host linux-x86_64          the host is x86-64 Linux (the link libraries and the QBE target are that host's)
#   eccp 1|0                   ROOT/build/edg/bin/eccp is executable (the bash checks it for a C++ input or an object link)
#   qbe 1|0                    ROOT/build/qbe/qbe is executable (the bash checks it for the Path B backend)
#   libc-a 1|0                 ROOT/build/edg/lib/libC.a exists (the link names it; the port refuses a link without it)
#   pathb-ldrt PATH            scripts/pathb-ldrt prints PATH (the long double helper archive)
#   ehshim PATH                scripts/ehshim prints PATH (absent or empty: it prints nothing, so the link has no EH shim)
#   sret PATH                  scripts/sret.sh prints PATH (absent or empty: nothing)
#   ld NAME                    ld.NAME is on PATH (for -fuse-ld=NAME; the other names pass to cc as they are)
#   module PATH                PATH declares or imports a C++ module (the bash reads the source; not ported)
#   exists PATH                PATH (relative to WORK) exists (the SYCL pre-pass test reads an -I directory's header)
#   pathb-status PATH CODE     scripts/pathb-cc exits with CODE on the source PATH (absent: 0)
#
# Assumed, not read: the environment (NFCXX_* variables are not read: the harness runs the bash with none), the
# repository tools (ensure_tool finds them fresh), the build of pathb-cc itself (its harness is inside pathb-cc: its status
# is the pathb-status fact), and the host GNU version and dialect (only an explicit --dialect reaches the command line).

require "pathname"

# A construct the port does not cover (exit 3): the bash may do anything with it, so nothing is guessed.
class NfcxxUnported < StandardError
end

# The bash ends with this status: a refusal it makes, or a pathb-cc status it passes on. The lines before it are printed.
class NfcxxExit < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end

# The bash replaces itself with the gcc fallback: the EXEC line is the last line of the plan.
class PlanExec < StandardError
end

DRIVER = "ROOT/nfcxx".freeze
PATHB_CC = "ROOT/scripts/pathb-cc".freeze
LIBC = "ROOT/build/edg/lib/libC.a".freeze
CHOICES = %w[default pathb gcc].freeze

def unported(what)
  raise NfcxxUnported, what
end

def exit_with(message, status)
  raise NfcxxExit.new(message, status)
end

# The facts the bash reads from the machine (see the header).
class Facts
  attr_reader :lds, :modules, :exists, :statuses

  def initialize
    @values = {}
    @lds = []
    @modules = []
    @exists = []
    @statuses = {}
  end

  def self.load(path)
    facts = new
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")

      key, rest = line.split(" ", 2)
      rest = rest.to_s
      case key
      when "ld" then facts.lds << rest
      when "module" then facts.modules << rest
      when "exists" then facts.exists << rest
      when "pathb-status"
        name, code = rest.split(" ", 2)
        facts.statuses[name] = code.to_i
      else facts.set(key, rest)
      end
    end
    facts
  end

  def set(key, value)
    @values[key] = value
  end

  def value(key)
    @values[key]
  end

  def flag?(key)
    @values[key] == "1"
  end

  def ld?(name)
    @lds.include?(name)
  end

  def module?(path)
    @modules.include?(path)
  end

  def exists?(path)
    @exists.include?(path)
  end

  def status(name)
    @statuses.fetch(name, 0)
  end
end

class Plan
  attr_reader :lines

  def initialize(facts, choice, args)
    @facts = facts
    @choice = choice
    @default = choice == "default"
    @args = args
    @lines = []
    @files = []    # the bash's files: link options, objects, sources, and -c (in order)
    @cflags = []   # -I, -D, -U (joined), for pathb-cc
    @preinc = []   # -include FILE
    @srcs = []
    @diag = []     # EDG diagnostic options (-Wno-narrowing)
    @ncpp = 0
    @nobj = 0
    @stdin_src = false
    @compile_only = false
    @outset = false
    @out = "a.out"
    @std = "23"
    @xlang = ""
    @pic = false
    @rdynamic = false
    @asan = false
    @safeptr = false
    @ir_opt = nil
    @dialect = "g++"
    @dialect_asked = false
    @gnu_user = nil
    @ld_name = nil
    @eh_shim = true
  end

  def run
    parse
    checks
    @pb_pre = @preinc.flat_map { |h| ["-include", h] }
    @pb_flags = pb_flags
    if @compile_only
      compile_path
    else
      link_path
    end
  end

  private

  def parse
    i = 0
    while i < @args.size
      x = @args[i]
      nxt = @args[i + 1]
      if x == "-fsyntax-only"
        unported("-fsyntax-only (nfcxx's type-check wrapper)")
      elsif x.start_with?("--backend=")
        unported("--backend in the arguments: the backend is the port's --backend")
      elsif x.start_with?("--ir-opt=")
        @ir_opt = x.delete_prefix("--ir-opt=")
      elsif x == "--eh-unwind" || x == "--no-eh-unwind"
        nil # with the gcc backend only (the EDG C side); Path B does not read it
      elsif x == "--no-eh-shim"
        @eh_shim = false
      elsif x.start_with?("--dialect=")
        @dialect = x.delete_prefix("--dialect=")
        @dialect_asked = true
      elsif x.start_with?("--gnu-version=")
        @gnu_user = x.delete_prefix("--gnu-version=")
      elsif x.start_with?("--")
        unported(x)
      elsif x.start_with?("-fuse-ld=")
        name = x.delete_prefix("-fuse-ld=")
        if @facts.ld?(name)
          @ld_name = name
        else
          @files << x
        end
      elsif x == "-fsanitize=address"
        @asan = true
      elsif x == "-fno-sanitize=address"
        @asan = false
      elsif x == "-fsafe-pointers"
        @safeptr = true
      elsif x == "-fno-safe-pointers"
        @safeptr = false
      elsif x == "-fno-sanitize=all"
        nil
      elsif x.start_with?("-fsanitize=") || x.start_with?("-fsanitize-") || x.start_with?("-fno-sanitize=")
        exit_with("nfcxx: #{x} is not supported (only -fsanitize=address; docs/notes/asan.md)", 2)
      elsif x == "-fno-omit-frame-pointer" || x == "-fomit-frame-pointer"
        nil # the options of the ASan C compile only
      elsif x == "-fPIC" || x == "-fpic"
        @pic = true
      elsif x == "-rdynamic"
        @rdynamic = true
      elsif x == "-shared"
        unported("-shared")
      elsif x == "-c"
        @compile_only = true
        @files << x
      elsif x == "-o"
        unported("-o with no file") if nxt.nil?
        @out = nxt
        @outset = true
        i += 1
      elsif x.start_with?("-std=c++")
        @std = x.delete_prefix("-std=c++")
      elsif x.start_with?("-std=gnu++")
        @std = x.delete_prefix("-std=gnu++")
      elsif x == "-E"
        unported("-E (the preprocessor path)")
      elsif x.start_with?("-M")
        unported("#{x} (dependency files)")
      elsif x == "-P"
        nil # for -E only
      elsif x == "-x"
        unported("-x with no language") if nxt.nil?
        @xlang = nxt
        i += 1
      elsif x == "-"
        @stdin_src = true
      elsif %w[-pthread -fexceptions -fwrapv -fno-strict-aliasing -pipe -fvisibility-inlines-hidden
               -fPIE -fpie -pie].include?(x) || x.start_with?("-fvisibility=")
        nil # EDG always lowers exceptions; the others reach only the gcc or EDG link, not pathb-cc
      elsif x.start_with?("-Wl,")
        @files << x
      elsif x.start_with?("-l") && x.size > 2
        @files << x
      elsif x == "-Wno-narrowing"
        @diag << "--diag_warning=narrowing_conversion"
      elsif x.start_with?("-W") || x == "-w"
        nil # warnings do not change the object code
      elsif x.start_with?("-m")
        nil # ISA options: their macros go to the bash's files list and are skipped there, and -fPIC-style picopts are gcc-only
      elsif x == "-include"
        unported("-include with no file") if nxt.nil?
        @preinc << nxt
        i += 1
      elsif x == "-isystem"
        unported("-isystem with no directory") if nxt.nil?
        i += 1 # the -isystem directories reach the -E and -M commands only
      elsif x.start_with?("-isystem")
        nil
      elsif x.end_with?(".c")
        unported("C source #{x} (the Path B C front end)")
      elsif (x.start_with?("-I") || x.start_with?("-D") || x.start_with?("-U")) && x.size > 2
        @cflags << x
        @files << x
      elsif x == "-I" || x == "-D" || x == "-U"
        exit_with("nfcxx: #{x} needs an argument", 2) if nxt.nil?
        @cflags << (x + nxt)
        @files << (x + nxt)
        i += 1
      elsif x.end_with?(".o")
        @files << x
        @nobj += 1
      elsif x.start_with?("-") || x.end_with?(".a") || x.end_with?(".so")
        @files << x
      elsif x.end_with?(".cu") || x.end_with?(".cpp2")
        unported("#{x} (CUDA or cppfront input)")
      else
        @files << x
        @ncpp += 1
        @srcs << x
      end
      i += 1
    end
  end

  # The checks the bash makes before the Path B section, in its order (only those that can print or end the plan).
  def checks
    exit_with("nfcxx: no input files", 2) if @ncpp + @nobj + (@stdin_src ? 1 : 0) == 0
    unported("-fsanitize=address (the ASan Path B checks)") if @asan
    unported("-fsafe-pointers (the safe-pointer checks)") if @safeptr
    exit_with("nfcxx: a source on stdin is supported only with -E", 2) if @stdin_src
    exit_with("nfcxx: -x #{@xlang}: only C++ sources (use nfcc for C)", 2) unless ["", "c++", "none"].include?(@xlang)
    if (@ncpp.positive? || @nobj.positive?) && !@facts.flag?("eccp")
      exit_with("nfcxx: EDG not built; run scripts/setup-edg.sh", 2)
    end
    exit_with("nfcxx: unknown dialect '#{@dialect}'", 2) if @dialect_asked && !%w[g++ clang].include?(@dialect)
    @srcs.each { |s| unported("C++ module source #{s}") if @facts.module?(s) }
    if @compile_only && @ncpp == 1 && @nobj.zero? && sycl_kernel_headers?
      unported("SYCL pre-pass (an -I directory has sycl/detail/kernel_desc.hpp)")
    end
    unported("-c with no C++ source (the bash links the objects with -c ignored)") if @compile_only && @ncpp.zero?
    unported("the gcc backend (scripts/nfcxx-gcc-plan.rb)") if @choice == "gcc"
    unported("host is not x86-64 Linux") unless @facts.value("host") == "linux-x86_64"
    exit_with("nfcxx: QBE not built; run scripts/setup-qbe.sh", 2) unless @facts.flag?("qbe")
  end

  # The SYCL test of the bash: an -I directory of the arguments holds sycl/detail/kernel_desc.hpp.
  def sycl_kernel_headers?
    prev = nil
    @args.each do |a|
      d = nil
      d = a.delete_prefix("-I") if a.start_with?("-I") && a.size > 2
      d = a if prev == "-I"
      prev = a
      next if d.nil? || d.empty?
      return true if @facts.exists?(Pathname.new(d).join("sycl/detail/kernel_desc.hpp").cleanpath.to_s)
    end
    false
  end

  # The options scripts/pathb-cc gets, in the order the bash appends them (pb_flags): --ir-opt, --pic, the EDG diagnostic
  # options, --dialect=clang (only when asked), --gnu-version.
  def pb_flags
    f = []
    f << "--ir-opt=#{@ir_opt}" unless @ir_opt.nil?
    f << "--pic" if @pic
    f.concat(@diag)
    f << "--dialect=clang" if @dialect == "clang" && @dialect_asked
    f << "--gnu-version=#{@gnu_user}" if @gnu_user && !@gnu_user.empty?
    f
  end

  # One pathb-cc call; returns its status (the pathb-status fact).
  def pathb_cc(source, dst)
    argv = [PATHB_CC, *@pb_flags, "-std=c++#{@std}", *@cflags, *@pb_pre, source, "-o", dst]
    @lines << "RUN #{argv.join(' ')}"
    @facts.status(source)
  end

  # A non-zero pathb-cc status: under the default backend the driver builds the program again with gcc (the EXEC line);
  # an explicit --backend=pathb ends with that status.
  def check_status(source, status)
    return if status.zero?
    exit_with("nfcxx: pathb-cc status #{status} on #{source}", status) unless @default
    warn "nfcxx: Path B did not build #{source} (status #{status}); building the program with the gcc backend, which " \
         "compiles with C semantics (-fwrapv -fno-strict-aliasing)"
    @lines << "EXEC env NFCXX_BACKEND=gcc #{DRIVER} #{@args.join(' ')}".rstrip
    raise PlanExec
  end

  # -c: one object per C++ file, named as the bash names it (basename without its last suffix, .o; -o names the one object).
  def compile_path
    @files.each do |x|
      next if x.start_with?("-") || x.end_with?(".o", ".a", ".so")

      dst = @outset ? @out : "#{File.basename(x).sub(/\.[^.]*\z/, '')}.o"
      check_status(x, pathb_cc(x, dst))
    end
  end

  # A link: each C++ file to a temporary object (TMP/pN.o), then cc with the objects and the link options, EDG's runtime
  # (libC.a) ahead of the host C++ library, as the bash links them.
  def link_path
    pobjs = []
    plink = []
    n = 0
    @files.each do |x|
      next if x.start_with?("-I", "-D", "-U")

      if x.start_with?("-") || x.end_with?(".o", ".a", ".so")
        plink << x
      else
        o = "TMP/p#{n}.o"
        n += 1
        check_status(x, pathb_cc(x, o))
        pobjs << o
      end
    end
    ldrt = @facts.value("pathb-ldrt")
    unported("scripts/pathb-ldrt printed no path") if ldrt.nil? || ldrt.empty?
    unported("#{LIBC} does not exist") unless @facts.flag?("libc-a")
    shim = []
    eh = @facts.value("ehshim")
    shim << eh if @eh_shim && eh && !eh.empty?
    sret = @facts.value("sret")
    shim << sret if sret && !sret.empty?
    ldopts = []
    ldopts << "-rdynamic" if @rdynamic
    ldopts << "-fuse-ld=#{@ld_name}" if @ld_name
    argv = ["cc", *ldopts, "-o", @out, *pobjs, *plink, ldrt, *shim, LIBC,
            "-lstdc++", "-lgcc_s", "-lpthread", "-lm", "-latomic"]
    @lines << "RUN #{argv.join(' ')}"
  end
end

def main(argv)
  facts_path = nil
  choice = "default"
  i = 0
  while i < argv.size && argv[i] != "--"
    a = argv[i]
    if a.start_with?("--facts=")
      facts_path = a.delete_prefix("--facts=")
    elsif a.start_with?("--backend=")
      choice = a.delete_prefix("--backend=")
    else
      warn "usage: nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG..."
      return 2
    end
    i += 1
  end
  args = argv[(i + 1)..] || []
  unless facts_path && CHOICES.include?(choice)
    warn "usage: nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG..."
    return 2
  end

  plan = Plan.new(Facts.load(facts_path), choice, args)
  begin
    plan.run
    plan.lines.each { |l| puts l }
    puts "STATUS 0"
  rescue PlanExec
    plan.lines.each { |l| puts l }
  rescue NfcxxExit => e
    plan.lines.each { |l| puts l }
    warn e.message unless e.message.empty?
    puts "STATUS #{e.status}"
  rescue NfcxxUnported => e
    warn "unported: #{e.message}"
    return 3
  end
  0
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__
