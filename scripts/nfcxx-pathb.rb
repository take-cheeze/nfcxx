#!/usr/bin/env ruby
# nfcxx's Path B compile and link of hosted C and C++ sources, ported from the bash in nfcxx: the backend choice, the argument
# loop for the options of this slice, the -fsyntax-only rewrite, the -E exec, the scripts/pathb-cc calls of a compile (C
# sources, then C++ files), the cp of a C-only -c, the link (one per source, then the cc link with EDG's runtime, the EH shim,
# the ASan VLA runtime and the safe-pointer runtime), and the fallback to the gcc backend that a default-selected Path B build
# takes when pathb-cc fails on a file. The argument loop is the one of nfcxx, for these options only (scripts/nfcxx-gcc-plan.rb
# has the same design for the gcc backend).
#
#   ruby scripts/nfcxx-pathb.rb --facts=FILE --backend=default|pathb -- ARG...
#
# --backend is the backend the driver is asked for: default (no --backend and no NFCXX_BACKEND: the driver picks Path B, and
# a file Path B fails on makes the driver build the program again with gcc), or pathb (--backend=pathb: the status of
# pathb-cc is the driver's status). gcc is scripts/nfcxx-gcc-plan.rb's, and is refused here. ARG... is the command line
# the bash gets, without --backend (an --backend in ARG... is refused).
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the status the bash ends with):
#   RUN PROGRAM ARG...     a program the driver runs: ROOT/scripts/pathb-cc (one source to an object), cp (a C-only -c) or
#                          cc (the link)
#   EXEC PROGRAM ARG...    the driver is replaced: the gcc fallback (exec env NFCXX_BACKEND=gcc ROOT/nfcxx ARG...), or the
#                          -E preprocess (exec g++ -E ...). The bash does not return from it, so no STATUS line follows; the
#                          status is the program's, not compared.
# ROOT stands for the repository and WORK for the working directory. The temporary directory of a compile or link is TMP
# (mktemp -d): the C objects TMP/N.o, the C++ objects of a link TMP/pN.o, and the -fsyntax-only object TMP/x.o. A refusal the
# bash makes (status 2, a pathb-cc status under --backend=pathb) prints the lines before it, then its status. A construct the
# port does not cover exits 3 with "unported: ..." on stderr and prints nothing (nothing is guessed).
#
# -fsyntax-only is the bash's own rewrite, not a plan of its own: its arguments are the compile of "-c ARGS -o TMP/x.o" (the
# -o value is replaced by TMP/x.o), or the -E path when -E is given. The port plans that command line.
#
# Modelled, with the bash's order of the lines: C sources (-c, and a link with C++ or alone), -E (exec g++ -E), -fsyntax-only,
# -fsanitize=address (--asan on the compile, the ASan link options, the VLA runtime), -fsafe-pointers (--safe-pointers, the
# runtime ahead of the objects), -shared (--pic and -shared on the link; the default backend takes gcc for it), the depfile
# options -MP, -MF, -MT, -MQ with -c, and -MD and -MMD with -c and an explicit --backend=pathb (the bash writes no depfile on
# the Path B compile: its -c path returns before the depfile). --cache, --cache-log, --time-log and --trace have no plan line
# of their own (the cache and the Path B paths return before the cache; the trace and time log write files, not commands).
#
# Not covered (exit 3): the gcc backend (the default with -shared, or with -MD or -MMD and no -fsafe-pointers, and the
# --backend=gcc choice); .cu and .cpp2 inputs (CUDA and cppfront: the rewriter, the device units and the prelinker) and the
# CUDA options; C++ modules; SYCL (a -I directory with the oneAPI kernel header); --freestanding, --cosmo, --target, --emit-c,
# --emit-hip, --bundle-libs, --cuda-driver, --module-dir, --instantiate, --keep-intermediates, and any other --option; -M and
# -MM and the other -M options that are not the depfile family (the bash passes -M and -MM on to cc or drops them, while its
# header comment says -M takes the gcc backend: the two disagree, so the port does not choose); -MD with -c of a file -fsafe-
# and -MMD with the default backend and no -fsafe-pointers (the default takes gcc for them); -c with no C++ or C source; -x
# with a language other than c++; -fsanitize=undefined and the other -fsanitize values (the bash exits 2 for them: refused).
#
# FILE holds the facts the bash reads from the machine and from its helper scripts (tests/nfcxx-pathb/run.sh writes it):
#   host linux-x86_64          the host is x86-64 Linux (the link libraries and the QBE target are that host's)
#   eccp 1|0                   ROOT/build/edg/bin/eccp is executable (the bash checks it for a C++ input or an object link)
#   qbe 1|0                    ROOT/build/qbe/qbe is executable (the bash checks it for the Path B backend)
#   libc-a 1|0                 ROOT/build/edg/lib/libC.a exists (the link names it; the port refuses a link without it)
#   pathb-ldrt PATH            scripts/pathb-ldrt prints PATH (the long double helper archive)
#   ehshim PATH                scripts/ehshim prints PATH (absent or empty: it prints nothing, so the link has no EH shim)
#   sret PATH                  scripts/sret.sh prints PATH (absent or empty: nothing)
#   asan-vla PATH              scripts/asan-vla prints PATH (the C++ VLA runtime of an ASan link; absent: the port refuses)
#   safeptr-rt PATH            scripts/safeptr-rt prints PATH (the safe-pointer runtime of a link; absent: the port refuses)
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

# The bash replaces itself (the gcc fallback, or the -E preprocess): the EXEC line is the last line of the plan.
class PlanExec < StandardError
end

DRIVER = "ROOT/nfcxx".freeze
PATHB_CC = "ROOT/scripts/pathb-cc".freeze
LIBC = "ROOT/build/edg/lib/libC.a".freeze
CHOICES = %w[default pathb gcc].freeze
FSO_OBJECT = "TMP/x.o".freeze # the object of -fsyntax-only (its temporary directory's x.o)

def unported(what)
  raise NfcxxUnported, what
end

def exit_with(message, status)
  raise NfcxxExit.new(message, status)
end

# The -fsyntax-only rewrite of nfcxx (the first loop of the script): with -E, the arguments without -fsyntax-only; otherwise
# "-c" then the arguments without -fsyntax-only, with the -o value (or a -o FILE added) pointing at the temporary object.
def fsyntax_only_args(args)
  return args unless args.include?("-fsyntax-only")

  base = args.reject { |a| a == "-fsyntax-only" }
  return base if base.include?("-E")

  return ["-c", *base, "-o", FSO_OBJECT] unless base.include?("-o")

  new_args = []
  skip = false
  base.each do |b|
    if skip
      new_args << FSO_OBJECT
      skip = false
      next
    end
    skip = true if b == "-o"
    new_args << b
  end
  unported("-fsyntax-only with a -o and no file") if skip
  ["-c", *new_args]
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
    @args = args
    @lines = []
    @files = []    # the bash's files: link options, objects, C++ sources, and -c (in order); not C sources
    @cflags = []   # -I, -D, -U (joined), for pathb-cc and the -E preprocess
    @preinc = []   # -include FILE
    @srcs = []     # C++ sources (in order)
    @cfiles = []   # C sources (in order)
    @c_objs = []   # the C objects of this plan (TMP/N.o)
    @sysdirs = []  # -isystem DIR (for the -E preprocess only)
    @ppflags = []  # -P (for the -E preprocess only)
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
    @shared = false
    @rdynamic = false
    @preprocess = false
    @asan = false
    @asanopts = []
    @safeptr = false
    @depmode = nil
    @ir_opt = nil
    @dialect = "g++"
    @dialect_asked = false
    @gnu_user = nil
    @ld_name = nil
    @eh_shim = true
    @default_backend = false
  end

  def run
    parse
    exit_with("nfcxx: no input files", 2) if @ncpp + @nobj + @cfiles.size + (@stdin_src ? 1 : 0) == 0
    preprocess_exec if @preprocess
    checks
    @pb_pre = @preinc.flat_map { |h| ["-include", h] }
    @pb_flags = pb_flags
    compile_c_files
    if @compile_only
      if @ncpp.zero?
        cp_c_objects
      else
        compile_path
      end
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
      if x.start_with?("--backend=")
        unported("--backend in the arguments: the backend is the port's --backend")
      elsif x.start_with?("--ir-opt=")
        @ir_opt = x.delete_prefix("--ir-opt=")
      elsif x == "--eh-unwind" || x == "--no-eh-unwind"
        nil # with the gcc backend only (the EDG C side); Path B does not read it
      elsif x == "--no-eh-shim"
        @eh_shim = false
      elsif x.start_with?("--cache=", "--cache-log=", "--time-log=", "--trace=")
        nil # no plan line: the cache is not reached by the Path B paths, the logs and traces write files
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
        @asanopts << x
      elsif x == "-fPIC" || x == "-fpic"
        @pic = true
      elsif x == "-rdynamic"
        @rdynamic = true
      elsif x == "-shared"
        @shared = true
        @pic = true
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
        @preprocess = true
      elsif x == "-P"
        @ppflags << x
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
      elsif x == "-MD" || x == "-MMD"
        @depmode = x
      elsif x == "-MP"
        nil # the phony targets of the depfile the bash writes for -MD or -MMD only
      elsif x == "-MF" || x == "-MT" || x == "-MQ"
        unported("#{x} with no file") if nxt.nil?
        i += 1
      elsif x.start_with?("-M")
        unported("#{x} (dependency options the port does not model)")
      elsif x == "-include"
        unported("-include with no file") if nxt.nil?
        @preinc << nxt
        i += 1
      elsif x == "-isystem"
        unported("-isystem with no directory") if nxt.nil?
        @sysdirs << nxt
        i += 1
      elsif x.start_with?("-isystem")
        @sysdirs << x.delete_prefix("-isystem")
      elsif x.end_with?(".c")
        @cfiles << x
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

  # The backend choice of the bash: default (Path B unless -shared or a depfile is asked for), or pathb. -fsafe-pointers takes
  # Path B whatever the choice. A default-selected build may fall back to gcc on a failure; the other Path B builds may not.
  def default_selected?
    @choice == "default" && !@shared && @depmode.nil?
  end

  # The checks the bash makes before the Path B section, in its order (only those that can print or end the plan).
  def checks
    exit_with("nfcxx: a source on stdin is supported only with -E", 2) if @stdin_src
    exit_with("nfcxx: -x #{@xlang}: only C++ sources (use nfcc for C)", 2) unless ["", "c++", "none"].include?(@xlang)
    exit_with("nfcxx: #{@depmode} needs -c (dependency files are written for a compile only)", 2) if @depmode && !@compile_only
    if (@ncpp.positive? || (@nobj.positive? && @cfiles.empty?)) && !@facts.flag?("eccp")
      exit_with("nfcxx: EDG not built; run scripts/setup-edg.sh", 2)
    end
    exit_with("nfcxx: unknown dialect '#{@dialect}'", 2) if @dialect_asked && !%w[g++ clang].include?(@dialect)
    @srcs.each { |s| unported("C++ module source #{s}") if @facts.module?(s) }
    if @compile_only && @ncpp == 1 && @nobj.zero? && @cfiles.empty? && sycl_kernel_headers?
      unported("SYCL pre-pass (an -I directory has sycl/detail/kernel_desc.hpp)")
    end
    unported("-c with no C++ or C source (the bash links the objects with -c ignored)") if @compile_only && @ncpp.zero? && @cfiles.empty?
    unported("the gcc backend (scripts/nfcxx-gcc-plan.rb)") if @choice == "gcc"
    unported("the gcc backend: the default is gcc for -shared and for -MD or -MMD (scripts/nfcxx-gcc-plan.rb)") unless
      @choice == "pathb" || @safeptr || default_selected?
    @default_backend = @choice == "default" && default_selected?
    exit_with("nfcxx: -fsanitize=address and -fsafe-pointers both replace malloc; use one", 2) if @asan && @safeptr
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

  # The -E exec of the bash: g++ preprocesses with the options in its order (-std, -x, -P, the -I/-D/-U, -isystem, -include,
  # the sources, - for stdin, -o). The C sources are not in it (the bash keeps them out of its source list).
  def preprocess_exec
    argv = ["-E", "-std=c++#{@std}"]
    argv += ["-x", @xlang] unless @xlang.empty?
    argv += @ppflags
    argv += @cflags
    argv += @sysdirs.map { |d| "-isystem#{d}" }
    argv += @preinc.flat_map { |h| ["-include", h] }
    argv += @srcs
    argv << "-" if @stdin_src
    argv += ["-o", @out] if @outset
    @lines << "EXEC g++ #{argv.join(' ')}"
    raise PlanExec
  end

  # The options scripts/pathb-cc gets, in the order the bash appends them (pb_flags): --safe-pointers, --ir-opt, --asan (Path
  # B only), --pic, the EDG diagnostic options, --dialect=clang (only when asked), --gnu-version.
  def pb_flags
    f = []
    f << "--safe-pointers" if @safeptr
    f << "--ir-opt=#{@ir_opt}" unless @ir_opt.nil?
    f << "--asan" if @asan
    f << "--pic" if @pic
    f.concat(@diag)
    f << "--dialect=clang" if @dialect == "clang" && @dialect_asked
    f << "--gnu-version=#{@gnu_user}" if @gnu_user && !@gnu_user.empty?
    f
  end

  # One pathb-cc call on a C++ source; returns its status (the pathb-status fact).
  def pathb_cc(source, dst)
    argv = [PATHB_CC, *@pb_flags, "-std=c++#{@std}", *@cflags, *@pb_pre, source, "-o", dst]
    @lines << "RUN #{argv.join(' ')}"
    @facts.status(source)
  end

  # A non-zero pathb-cc status: under the default backend the driver builds the program again with gcc (the EXEC line);
  # an explicit --backend=pathb ends with that status.
  def check_status(source, status)
    return if status.zero?
    exit_with("nfcxx: pathb-cc status #{status} on #{source}", status) unless @default_backend
    warn "nfcxx: Path B did not build #{source} (status #{status}); building the program with the gcc backend, which " \
         "compiles with C semantics (-fwrapv -fno-strict-aliasing)"
    @lines << "EXEC env NFCXX_BACKEND=gcc #{DRIVER} #{@args.join(' ')}".rstrip
    raise PlanExec
  end

  # The C sources, each to an object TMP/N.o (N counts the C sources), with the C options of the bash: no -fwrapv, no -include.
  # Before the C++ files, as the bash does.
  def compile_c_files
    @cfiles.each_with_index do |c, n|
      dst = "TMP/#{n}.o"
      argv = [PATHB_CC, *@pb_flags, "-std=c11", *@cflags, c, "-o", dst]
      @lines << "RUN #{argv.join(' ')}"
      check_status(c, @facts.status(c))
      @c_objs << dst
    end
  end

  # A C-only -c: the objects are the output, each copied to -o FILE (one source only) or to basename.o.
  def cp_c_objects
    exit_with("nfcxx: -c with -o needs exactly one source", 2) if @outset && @c_objs.size != 1
    @cfiles.each_with_index do |c, i|
      dst = @outset ? @out : "#{File.basename(c).sub(/\.c\z/, '')}.o"
      @lines << "RUN cp #{@c_objs[i]} #{dst}"
    end
  end

  # -c: one object per C++ file, named as the bash names it (basename without its last suffix, .o; -o names the one object).
  def compile_path
    @files.each do |x|
      next if x.start_with?("-") || x.end_with?(".o", ".a", ".so")

      dst = @outset ? @out : "#{File.basename(x).sub(/\.[^.]*\z/, '')}.o"
      check_status(x, pathb_cc(x, dst))
    end
  end

  # The options of the link's cc: -shared (a shared object), -rdynamic, -fuse-ld=NAME, in the bash's order.
  def ldopts
    o = []
    o << "-shared" if @shared
    o << "-rdynamic" if @rdynamic
    o << "-fuse-ld=#{@ld_name}" if @ld_name
    o
  end

  # The options of every C compile and link of an ASan program (the bash's asan_c), for the link's cc.
  def asan_c
    return [] unless @asan

    ["-fsanitize=address", "-fno-omit-frame-pointer", *@asanopts]
  end

  def fact_path(key)
    v = @facts.value(key)
    unported("scripts/#{key} printed no path") if v.nil? || v.empty?
    v
  end

  # The link's cc (the bash's hosted block): the EH shim and the sret objects, and with -fsanitize=address the C++ VLA runtime.
  # Neither is added to a -shared link or a link with no C++ or object input (the block is not entered).
  def hosted_extras
    return [[], []] if @shared

    shim = []
    eh = @facts.value("ehshim")
    shim << eh if @eh_shim && eh && !eh.empty?
    sret = @facts.value("sret")
    shim << sret if sret && !sret.empty?
    vla = @asan ? [fact_path("asan-vla")] : []
    [shim, vla]
  end

  # A link: each C++ file to a temporary object (TMP/pN.o), then cc with the objects and the link options, EDG's runtime
  # (libC.a) ahead of the host C++ library, as the bash links them. Before the compiles, the facts the link names are read: a
  # missing one is unported here (the bash would fail the link after the compiles, or before them).
  def link_path
    if @ncpp.zero? && (@nobj.zero? || !@facts.flag?("eccp"))
      return c_only_link
    end

    unported("#{LIBC} does not exist") unless @facts.flag?("libc-a")
    ldrt = fact_path("pathb-ldrt")
    shim, vla = hosted_extras
    sprt = @safeptr ? [fact_path("safeptr-rt"), "-pthread"] : []
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
    argv = ["cc", *asan_c, *ldopts, "-o", @out, *sprt, *@c_objs, *pobjs, *plink, ldrt, *shim, *vla,
            LIBC, "-lstdc++", "-lgcc_s", "-lpthread", "-lm", "-latomic"]
    @lines << "RUN #{argv.join(' ')}"
  end

  # The link of C sources alone (or with object files when eccp is not built): cc with the C objects, every link option of the
  # command line (the -I, -D and -U options too), the VLA runtime of an ASan link, EDG's runtime and the host C++ library.
  def c_only_link
    unported("#{LIBC} does not exist") unless @facts.flag?("libc-a")
    ldrt = fact_path("pathb-ldrt")
    cvla = @asan ? [fact_path("asan-vla")] : []
    argv = ["cc", *asan_c, *ldopts, *@c_objs, *@files, *cvla, "-o", @out, ldrt, LIBC, "-lstdc++", "-lm", "-latomic"]
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

  begin
    plan = Plan.new(Facts.load(facts_path), choice, fsyntax_only_args(args))
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
