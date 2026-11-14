#!/usr/bin/env ruby
# nfcxx's gcc-backend compile and link dispatch, ported from the bash in nfcxx: the setup after the argument loop (the
# isa, asan and sanitize options, the host headers, the EH shim and VLA runtime of a link), the C inputs (gcc), the link
# of C-only programs, and the EDG driver call (eccp) that compiles and links C++ sources, plus the -E preprocess and the
# -MD dependency step that follows the eccp call. The argument loop is the one of scripts/nfcxx-loop.rb, copied here for the
# options in this slice (nfcxx-loop.rb is a script with a main, so it is not required).
#
#   ruby scripts/nfcxx-gcc-plan.rb --facts=FILE ARG...
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the exit status the bash ends with):
#   RUN PROGRAM ARG...     a program the driver runs (gcc, g++, cp's CP below, the EDG driver as ROOT/build/edg/bin/eccp)
#   EXEC PROGRAM ARG...    the program replaces nfcxx (-E: exec g++ -E)
#   CP SRC DST             a copy (the objects of a C-only -c)
#   ENV NAME=VALUE         a variable the bash exports for the program that follows (EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS, -shared)
# ROOT stands for the repository and WORK for the working directory; TMP for a temporary directory (mktemp -d).
# An argument list outside the gcc backend (Path B by default, cosmo, the CUDA inputs, a cache lookup, modules, cppfront,
# freestanding, ...) exits 3 with "unported: ..." on stderr and prints nothing. A refusal the bash makes (status 2) prints
# the lines before it, then its status. Modelled here: -fsyntax-only (the re-run as -c -o TMP/x.o, as nfcxx-loop.rb's
# syntax_only_plan has it; -E execs g++ -E), --cuda-driver= and a link that names libcuda (the re-run of
# scripts/cuda-driver-wrap.sh, or its note, or its error), and --cache=DIR when the compile is not one a cache lookup
# keys (a link, several sources, -MD, an -o without an extension). A -c of one source with --cache is unported: its key
# hashes the scripts and binaries.
#
# FILE holds the facts the bash reads from the machine and from its helper scripts (tests/nfcxx-gcc/run.sh writes it):
#   host-sys DIR            a directory of the host C++ library, in host_sys_includes' order
#   isa FLAG NAME VALUE     a macro that the -m option FLAG adds (the difference of gcc -dM with and without FLAG)
#   ld NAME                 ld.NAME is on PATH (for -fuse-ld=NAME)
#   exists PATH             PATH (relative to WORK) is an existing file or directory (abs_path and -e tests)
#   module PATH             PATH declares or imports a C++ module (the module check reads the source; not ported)
#   cxx-clang 0|1           the host C++ compiler (g++) is clang
#   cc-clang 0|1            the C compiler (cc) is clang
#   ehshim PATH             scripts/ehshim prints PATH (absent: it prints nothing)
#   sret PATH               scripts/sret.sh prints PATH (absent: nothing)
#   asan-vla PATH           scripts/asan-vla prints PATH (absent: it fails)
#   eh-tls 1                ${EDG}/../eh-tls exists
#   dir PATH                PATH (relative to WORK) is an existing directory (the exists lines cover files and directories)
#   machine M               uname -m
#   cuda-home PATH          CUDA_HOME is PATH (no line: CUDA_HOME is unset)
#   cuda-cub PATH           scripts/cuda-cub prints PATH (no line: it prints nothing and fails)
#   cuda-shim PATH          scripts/cuda-driver-shim prints PATH (the shim's archive)
#   cuda-shim-error TEXT    scripts/cuda-driver-shim fails with TEXT (takes precedence over cuda-shim)
#   cuda-rtv PATH N         the header PATH has "#define CUDART_VERSION N"
#   cuda-file, cuda-dir     run.sh makes these in the work directory; the port reads the exists and dir lines instead
#
# Assumed, not read: the environment (NFCXX_* variables are not read: the harness runs the bash with none, and CUDA_HOME
# only as the cuda-home fact), the SYCL pre-pass (it needs a sycl include in the source), the existence of eccp and of the
# built repository tools (ensure_tool finds them fresh, so no ninja run), and the host GNU version (not used by this path).
# A CUDA toolkit that is /usr/local/cuda (CUDA_HOME unset, and the libcuda path does not name a toolkit with cuda.h) is
# not read: unported.

require "pathname"

class NfcxxUnported < StandardError
end

# the bash ends here with status 0 (after a copy the -c of C sources makes, or the link of a C-only program)
class PlanDone < StandardError
end

class NfcxxExit < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end

ROOT = "ROOT".freeze
CWD = "WORK".freeze
ECCP = "ROOT/build/edg/bin/eccp".freeze
LIBC = "ROOT/build/edg/lib/libC.a".freeze
EH_UNWIND_HEADER = "ROOT/lib/ehshim/nfcxx_eh_unwind.h".freeze

# The facts the bash reads from the machine (see the header).
class Facts
  attr_reader :host_sys, :isa, :ld, :exists, :modules, :dirs

  def initialize
    @host_sys = []
    @isa = []
    @ld = []
    @exists = []
    @modules = []
    @dirs = []
    @rtv = {}
    @values = {}
  end

  def self.load(path)
    facts = new
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")

      key, rest = line.split(" ", 2)
      rest = rest.to_s
      case key
      when "host-sys" then facts.host_sys << rest
      when "isa"
        flag, name, value = rest.split(" ", 3)
        facts.isa << [flag, name, value.to_s]
      when "ld" then facts.ld << rest
      when "exists" then facts.exists << rest
      when "module" then facts.modules << rest
      when "dir" then facts.dirs << rest
      when "cuda-rtv"
        path, version = rest.split(" ", 2)
        facts.cuda_rtv_set(path, version)
      when "cuda-file", "cuda-dir" then nil
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

  def exists?(path)
    @exists.include?(path)
  end

  # a regular file (the bash's -f): it exists and is not a directory
  def file?(path)
    exists?(path) && !@dirs.include?(path)
  end

  def dir?(path)
    @dirs.include?(path)
  end

  def cuda_rtv_set(path, version)
    @rtv[path] = version
  end

  # the CUDART_VERSION of the header at PATH (nil when the header has no such line)
  def cuda_rtv(path)
    @rtv[path]
  end
end

def unported(what)
  raise NfcxxUnported, what
end

def normalize(path)
  Pathname.new(path).cleanpath.to_s
end

# options of the argument loop that the gcc path does not port (the other tracks, or the tools they need)
UNPORTED_PREFIXES = ["--bundle-", "--time-log=", "--trace=", "--module-dir=", "--target=",
                     "--pathb-c=", "--ir-opt=", "--promote-slots=", "--unroll=", "--struct-slots=", "--emit-"].freeze
UNPORTED_OPTIONS = ["--cosmo", "--freestanding", "--obfuscate-kernels", "-fsafe-pointers"].freeze

class Plan
  attr_reader :lines

  # lines: the output (a nested run, the -fsyntax-only or --cuda-driver= re-run, appends to it); env_mode: the mode of
  # NFCXX_CUDA_DRIVER for this run ("libcuda" for the run the wrap execs, which has the mode in its environment)
  def initialize(facts, lines = [], env_mode = "auto")
    @facts = facts
    @lines = lines
    @env_mode = env_mode
    @cache_dir = ""
    @std = "--c++23"
    @out = "a.out"
    @outset = false
    @dialect = facts.flag?("cxx-clang") ? "clang" : "g++"
    @backend = ""
    @backend_explicit = false
    @emit_c = 0
    @cosmo = 0
    @target = ""
    @instantiate = "used"
    @eh_unwind_on = false
    @eh_shim_on = true
    @asan = false
    @asanopts = []
    @pic = false
    @shared = false
    @rdynamic = false
    @pthread = false
    @compile_only = false
    @preprocess = false
    @xlang = ""
    @stdin_src = false
    @depmode = ""
    @dfile = ""
    @dtarget = ""
    @depphony = ""
    @ncpp = 0
    @nobj = 0
    @ld_name = ""
    @files = []
    @cflags = []
    @cfiles = []
    @srcs = []
    @ppflags = []
    @pie_opts = []
    @preinc = []
    @sysdirs = []
    @isa_opts = []
    @diag_opts = []
    @dialect_asked = false
  end

  # the argument loop (scripts/nfcxx-loop.rb's run_loop, for the options of this slice)
  def parse(args)
    i = 0
    while i < args.length
      a = args[i]
      nxt = args[i + 1].to_s
      if UNPORTED_OPTIONS.include?(a) || UNPORTED_PREFIXES.any? { |p| a.start_with?(p) }
        unported(a)
      elsif a == "--backend=pathb" then unported("--backend=pathb (Path B)")
      elsif a.start_with?("--backend=") then @backend = a[10..]; @backend_explicit = true
      elsif a == "--keep-intermediates" || a == "--no-eh-unwind" then nil
      elsif a == "--eh-unwind" then @eh_unwind_on = true
      elsif a == "--no-eh-shim" then @eh_shim_on = false
      elsif a.start_with?("--cache=") then @cache_dir = a[8..]
      elsif a.start_with?("--cache-log=") then nil
      elsif a.start_with?("--instantiate=") then @instantiate = a[14..]
      elsif a.start_with?("--dialect=") then @dialect = a[10..]; @dialect_asked = true
      elsif a.start_with?("--gnu-version=") then nil
      elsif a.start_with?("-fuse-ld=")
        name = a[9..]
        if @facts.ld.include?(name) then @ld_name = name else @files << a end
      elsif a == "-fsanitize=address" then @asan = true
      elsif a == "-fno-sanitize=address" then @asan = false
      elsif a == "-fno-sanitize=all" then nil
      elsif a.start_with?("-fsanitize=", "-fsanitize-")
        raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=address; docs/notes/asan.md)", 2)
      elsif a.start_with?("-fno-sanitize=", "-fno-sanitize-")
        raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=undefined and its checks, docs/notes/ubsan.md)", 2)
      elsif a == "-fno-safe-pointers" then nil
      elsif a == "-fno-omit-frame-pointer" || a == "-fomit-frame-pointer" then @asanopts << a
      elsif a == "-shared" then @shared = true; @pic = true
      elsif a == "-fPIC" || a == "-fpic" then @pic = true
      elsif a == "-rdynamic" then @rdynamic = true
      elsif a == "-c" then @compile_only = true; @files << "-c"
      elsif a == "-o" then @out = nxt; @outset = true; i += 1
      elsif a.start_with?("-std=c++") then @std = "--c++#{a[8..]}"
      elsif a.start_with?("-std=gnu++") then @std = "--c++#{a[10..]}"
      elsif a == "-E" then @preprocess = true
      elsif a == "-P" then @ppflags << "-P"
      elsif a == "-x" then @xlang = nxt; i += 1
      elsif a == "-" then @stdin_src = true
      elsif a == "-pthread" then @pthread = true
      elsif a == "-fexceptions" || a == "-fwrapv" || a == "-fno-strict-aliasing" || a == "-pipe" then nil
      elsif a.start_with?("-fvisibility=") || a == "-fvisibility-inlines-hidden" then nil
      elsif a == "-fPIE" || a == "-fpie" then @pie_opts.push("--c_to_obj_option", "-fPIE")
      elsif a == "-pie" then @pie_opts.push("--c_to_obj_option", "-pie")
      elsif a.start_with?("-Wl,") then @files << a
      elsif a.start_with?("-l") && a.length > 2
        @files << a
      elsif a == "-Wno-narrowing" then @diag_opts << "--diag_warning=narrowing_conversion"
      elsif a.start_with?("-W") || a == "-w" then nil
      elsif a.start_with?("-m") then @isa_opts << a
      elsif a == "-MD" || a == "-MMD" then @depmode = a
      elsif a == "-MP" then @depphony = "-MP"
      elsif a == "-MF" then @dfile = nxt; i += 1
      elsif a == "-MT" || a == "-MQ" then @dtarget = nxt; i += 1
      elsif a == "-include"
        raise NfcxxExit.new("nfcxx: -include needs an argument", 2) unless i + 1 < args.length
        @preinc << nxt; i += 1
      elsif a == "-isystem"
        @sysdirs << nxt; i += 1
      elsif a.start_with?("-isystem") && a.length > 8 then @sysdirs << a[8..]
      elsif a.end_with?(".c") then @cfiles << a
      elsif (a.start_with?("-I", "-D", "-U")) && a.length > 2
        @cflags << a
        @files << a
      elsif a == "-I" || a == "-D" || a == "-U"
        raise NfcxxExit.new("nfcxx: #{a} needs an argument", 2) unless i + 1 < args.length
        @cflags << "#{a}#{nxt}"
        @files << "#{a}#{nxt}"
        i += 1
      elsif a.end_with?(".o")
        @files << a
        @nobj += 1
      elsif a.start_with?("-") || a.end_with?(".a") || a.end_with?(".so")
        @files << a
      elsif a.end_with?(".cu", ".cpp2") then unported("CUDA or cppfront input #{a}")
      else
        @files << a
        @ncpp += 1
        @srcs << a
      end
      i += 1
    end
  end

  def run(args)
    return syntax_only(args) if args.include?("-fsyntax-only")

    kind, argv = cuda_driver_step(args)
    return nested(argv, "libcuda") if kind == :exec

    parse(argv)
    if @ncpp + @nobj + @cfiles.length + (@stdin_src ? 1 : 0) == 0
      raise NfcxxExit.new("nfcxx: no input files", 2)
    end
    @srcs.each { |s| unported("module source #{s}") if @facts.modules.include?(s) }
    return preprocess if @preprocess

    raise NfcxxExit.new("nfcxx: a source on stdin is supported only with -E", 2) if @stdin_src
    unless ["", "c++", "none"].include?(@xlang)
      raise NfcxxExit.new("nfcxx: -x #{@xlang}: only C++ sources (use nfcc for C)", 2)
    end
    if !@depmode.empty? && !@compile_only
      raise NfcxxExit.new("nfcxx: #{@depmode} needs -c (dependency files are written for a compile only)", 2)
    end
    raise NfcxxExit.new("nfcxx: unknown dialect '#{@dialect}'", 2) unless ["g++", "clang"].include?(@dialect)

    select_backend
    # a -c of one source with -o and an extension is looked up in the object cache (the key is not modelled)
    if !@cache_dir.empty? && @compile_only && @ncpp == 1 && @outset && @nobj == 0 && @cfiles.empty? && @depmode.empty? &&
       @out.include?(".")
      unported("--cache of a -c compile: its key hashes the scripts, the binaries and the host compilers")
    end
    @moves = !@compile_only
    asan_c = @asan ? ["-fsanitize=address", "-fno-omit-frame-pointer", *@asanopts] : []
    @asanopts = [] unless @asan
    inst_opts = instantiate_options
    sys_inc = []
    hosted_libs = []
    @facts.host_sys.each { |d| sys_inc << "--sys_include=#{d}" }
    hosted_libs = ["--c_to_obj_lib=m"]
    @sysdirs.each { |d| sys_inc << "--sys_include=#{ecp_arg(d)}" }
    pre_opts = []
    @preinc.each do |f|
      f = abs(f) if @moves && @facts.exists?(f)
      pre_opts.push("--preinclude", f)
    end
    shim, rtlib, vlart = link_helpers
    picopts, ldopts, cflags_pic = pic_and_link_options(asan_c)
    cobjs = c_inputs(asan_c, cflags_pic, ldopts)
    link_files = @files + isa_defines
    eflist, userinc = edg_link_options(link_files)
    keep_static = @facts.flag?("cc-clang") ? [] : ["--c_to_obj_option", "-fkeep-static-functions"]
    eh_unwind = []
    eh_unwind << "--nfcxx_eh_thread_local" if @facts.flag?("eh-tls")
    if @eh_unwind_on && @backend == "gcc"
      eh_unwind += ["--nfcxx_eh_unwind", "--c_to_obj_option", "-fexceptions", "--c_to_obj_option", "-include",
                    "--c_to_obj_option", EH_UNWIND_HEADER]
    end
    if @shared
      lk = ["-shared"]
      prev = nil
      (picopts + eflist + inst_opts).each do |a|
        lk << a if prev == "--c_to_obj_option" && (a.start_with?("-Wl,", "-fuse-ld=") || a == "-pthread" || a == "-rdynamic")
        prev = a
      end
      emit("ENV", "EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=#{lk.join(" ")}")
    end
    emit("RUN", ECCP, @std, "--#{@dialect}", "--wdir", "/", *inst_opts, *@diag_opts, *userinc, *sys_inc, *hosted_libs,
         "--c_to_obj_option", "-O2", "--c_to_obj_option", "-fwrapv", "--c_to_obj_option", "-fno-strict-aliasing",
         *keep_static, *eh_unwind, "--c_to_obj_option", "-fgnu89-inline", *picopts, *cobjs, *pre_opts, *eflist,
         *shim, *vlart, *rtlib, "-o", ecp_arg(@out))
    depend_step unless @depmode.empty?
    nil
  end

  private

  def emit(kind, *words)
    @lines << [kind, *words].join(" ")
  end

  # the backend: an explicit --backend=, else gcc unless the default would be Path B (which is not ported)
  def select_backend
    if @backend.empty?
      if !@backend_explicit && @cosmo == 0 && @emit_c == 0 && @target.empty? && !@preprocess && @depmode.empty? && !@shared
        unported("the default backend is Path B for this argument list (give --backend=gcc)")
      end
      @backend = "gcc"
    end
    raise NfcxxExit.new("nfcxx: unknown backend '#{@backend}'", 2) unless ["pathb", "gcc"].include?(@backend)
    unported("--backend=pathb") if @backend == "pathb"
  end

  def instantiate_options
    case @instantiate
    when "auto" then []
    when "used"
      opts = ["--no_auto_instantiation", "-tused"]
      opts += ["--c_to_obj_option", "-ffunction-sections", "--c_to_obj_option", "-fdata-sections",
               "--c_to_obj_option", "-Wl,--gc-sections"]
      opts
    else
      raise NfcxxExit.new("nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got #{@instantiate})", 2)
    end
  end

  # ecp_arg: an argument as eccp receives it (paths absolute when eccp runs in a temporary directory: a link)
  def ecp_arg(arg)
    return arg unless @moves

    case arg
    when /\A-I./ then "-I#{abs(arg[2..])}"
    when /\A-L./ then "-L#{abs(arg[2..])}"
    when /\A-Wl,/ then wl_arg(arg)
    when /\A-/ then arg
    else abs(arg)
    end
  end

  # abs_path: the absolute name when the directory of the path exists (the path itself need not)
  def abs(path)
    return normalize(path) if path.start_with?("/")
    return path unless dir_exists?(File.dirname(path))

    normalize(File.join(CWD, path))
  end

  def dir_exists?(dir)
    dir == "." || @facts.exists?(dir)
  end

  def wl_arg(arg)
    parts = arg[4..].split(",", -1)
    res = "-Wl"
    prevp = nil
    parts.each do |p|
      if ["-soname", "--soname", "-h"].include?(prevp)
        res += ",#{p}"
        prevp = p
        next
      end
      prevp = p
      if p.match?(/\A(-soname=|--soname=)/) then nil
      elsif p.match?(/\A(--dependency-file=|-Map=|--Map=)/)
        name, value = p.split("=", 2)
        if @facts.exists?(value) || dir_exists?(File.dirname(value))
          p = "#{name}=#{abs(File.dirname(value))}/#{File.basename(value)}"
        end
      elsif p.include?("=")
        name, value = p.split("=", 2)
        p = "#{name}=#{abs(value)}" if @facts.exists?(value)
      elsif @facts.exists?(p)
        p = abs(p)
      end
      res += ",#{p}"
    end
    res
  end

  def isa_defines
    return [] if @isa_opts.empty?

    defs = @facts.isa.select { |flag, _, _| @isa_opts.include?(flag) }
    defs.map { |_, name, value| [name, value] }.uniq.sort_by { |name, value| "#{name} #{value}" }
        .map { |name, value| "-D#{name}=#{value}" }
  end

  # the EH shim and the VLA runtime of a hosted link (the block before the C inputs)
  def link_helpers
    shim = []
    rtlib = []
    vlart = []
    return [shim, rtlib, vlart] unless !@compile_only && !@shared && (@ncpp + @nobj) > 0

    s = @eh_shim_on ? @facts.value("ehshim").to_s : ""
    shim << s unless s.empty?
    sret = @facts.value("sret").to_s
    shim << sret unless sret.empty?
    rtlib = [LIBC]
    if @asan
      v = @facts.value("asan-vla").to_s
      raise NfcxxExit.new("nfcxx: cannot build the C++ VLA runtime for -fsanitize=address (scripts/asan-vla)", 2) if v.empty?

      vlart = [v]
    end
    [shim, rtlib, vlart]
  end

  # the picopts and ldopts of the bash (the -m options, the -fPIC reset, the link options)
  def pic_and_link_options(asan_c)
    picopts = []
    ldopts = []
    cflags_pic = []
    @isa_opts.each { |o| picopts.push("--c_to_obj_option", o) }
    if @pic
      picopts = ["--c_to_obj_option", "-fPIC"]
      cflags_pic = ["-fPIC"]
    end
    picopts.push("--c_to_obj_option", "-rdynamic") if @rdynamic
    picopts.push("--c_to_obj_option", "-pthread") if @pthread
    picopts += @pie_opts
    asan_c.each { |o| picopts.push("--c_to_obj_option", o) }
    ldopts = ["-shared"] if @shared
    ldopts << "-rdynamic" if @rdynamic
    unless @ld_name.empty?
      ldopts << "-fuse-ld=#{@ld_name}"
      picopts.push("--c_to_obj_option", "-fuse-ld=#{@ld_name}")
    end
    [picopts, ldopts, cflags_pic]
  end

  # the C inputs: one gcc object each (a -c of C alone copies them; a C-only program links with gcc and stops)
  def c_inputs(asan_c, cflags_pic, ldopts)
    cobjs = []
    return cobjs if @cfiles.empty?

    @cfiles.each_with_index do |c, n|
      o = "TMP/#{n}.o"
      emit("RUN", "gcc", "-c", "-O2", "-fwrapv", "-fno-strict-aliasing", *asan_c, *cflags_pic, *@cflags, c, "-o", o)
      cobjs << o
    end
    if @compile_only && @ncpp == 0
      raise NfcxxExit.new("nfcxx: -c with -o needs exactly one source", 2) if @outset && cobjs.length != 1

      cobjs.each_with_index do |o, i|
        dst = @outset ? @out : "#{File.basename(@cfiles[i], ".c")}.o"
        emit("CP", o, dst)
      end
      raise PlanDone
    end
    if @ncpp == 0 && @nobj == 0
      emit("RUN", "gcc", *asan_c, *ldopts, *cobjs, *(@files + isa_defines), "-o", @out)
      raise PlanDone
    end
    cobjs
  end

  # the link options of the EDG call: -l, -L, -Wl, and the rest, in argument order
  def edg_link_options(files)
    eflist = []
    userinc = []
    no_as_needed = false
    as_needed = false
    files.each do |f|
      case f
      when /\A-I./ then userinc << ecp_arg(f)
      when "-lcudart"
        # scripts/nfcxx-loop's -lcudart: the run path of a CUDA_HOME's lib64, the CUB archive (links only), libcudart
        home = @facts.value("cuda-home").to_s
        eflist.push("--c_to_obj_option", "-Wl,-rpath,#{home}/lib64") if !home.empty? && @facts.dir?("#{home}/lib64")
        unless @compile_only
          cub = @facts.value("cuda-cub").to_s
          eflist << cub unless cub.empty?
        end
        eflist << "--c_to_obj_lib=cudart"
      when /\A-l./ then eflist << "--c_to_obj_lib=#{f[2..]}"
      when "-Wl,--no-as-needed"
        no_as_needed = true
      when /\A-Wl,--no-as-needed,/
        no_as_needed = true
        f.delete_prefix("-Wl,--no-as-needed,").split(",", -1).each do |item|
          if item.start_with?("-l") && item.length > 2 then eflist << "--c_to_obj_lib=#{item[2..]}"
          elsif item.start_with?("-") then eflist.push("--c_to_obj_option", ecp_arg("-Wl,#{item}"))
          else eflist << ecp_arg(item)
          end
        end
      when "-Wl,--as-needed" then as_needed = true
      when /\A-Wl,(--whole-archive|--no-whole-archive|--start-group|--end-group|--as-needed|-Bstatic|-Bdynamic)(,|\z)/
        raise NfcxxExit.new("nfcxx: #{f}: an order-dependent link option cannot be kept with C++ inputs (docs/notes/cxx-driver.md)", 2)
      when /\A-Wl,/ then eflist.push("--c_to_obj_option", ecp_arg(f))
      else eflist << ecp_arg(f)
      end
    end
    if no_as_needed
      eflist.push("--c_to_obj_option", "-Wl,--no-as-needed")
    elsif as_needed
      eflist.push("--c_to_obj_option", "-Wl,--as-needed")
    end
    [eflist, userinc]
  end

  # the run of nfcxx on ARGV, in the same output (the bash runs it as a new process)
  def nested(argv, mode)
    Plan.new(@facts, @lines, mode).run(argv)
  end

  # -fsyntax-only (the first step of the bash): the compile without its object, run as -c -o TMP/x.o, its -o value
  # replaced (the same rule as scripts/nfcxx-loop.rb's syntax_only_plan). With -E the run goes on without the option, and
  # that run execs g++ -E.
  def syntax_only(args)
    rest = args.reject { |b| b == "-fsyntax-only" }
    return nested(rest, @env_mode) if rest.include?("-E")

    if rest.include?("-o")
      unported("-o with no value under -fsyntax-only") if rest.last == "-o"
      replaced = []
      skip = false
      rest.each do |b|
        if skip
          replaced << "TMP/x.o"
          skip = false
          next
        end
        skip = true if b == "-o"
        replaced << b
      end
      return nested(["-c", *replaced], @env_mode)
    end
    nested(["-c", *rest, "-o", "TMP/x.o"], @env_mode)
  end

  def libcuda?(arg)
    ["-lcuda", "-l:libcuda.so", "-l:libcuda.so.1"].include?(arg) || arg.end_with?("/libcuda.so", "/libcuda.so.1")
  end

  def cuda_static?(arg)
    arg == "-lcudart_static" || arg.end_with?("/libcudart_static.a")
  end

  # the toolkit a libcuda path implies (scripts/cuda-driver-wrap.sh: the directory above lib64, or above lib/stubs for a
  # targets/ path); "" when it implies none
  def derived_home(found)
    if found.match?(%r{/lib64/(stubs/)?libcuda\.so}) then found[0...found.rindex("/lib64/")]
    elsif found.match?(%r{/targets/.*/lib/stubs/libcuda\.so}) then found[0...found.rindex("/lib/stubs/")]
    else ""
    end
  end

  # the toolkit: CUDA_HOME when it is set, else the derived one when it has include/cuda.h, else /usr/local/cuda (not read)
  def cuda_toolkit(found)
    env_home = @facts.value("cuda-home").to_s
    return env_home unless env_home.empty?

    home = derived_home(found)
    return home if !home.empty? && @facts.file?("#{home}/include/cuda.h")

    unported("the CUDA toolkit is /usr/local/cuda (CUDA_HOME unset, and #{found} names no toolkit with cuda.h): not read")
  end

  # the reason the wrap cannot replace libcuda with the shim, or nil (the bash's why)
  def cuda_why(home)
    # the wrap reads the runtime header's CUDART_VERSION first: a missing header fails the sed, and the script with it
    header = "#{home}/include/cuda_runtime_api.h"
    raise NfcxxExit.new("nfcxx: cuda-driver-wrap: sed cannot read #{header}", 2) unless @facts.file?(header)

    machine = @facts.value("machine") or unported("uname -m is not in the facts")
    return "the shim is x86-64 only" unless machine == "x86_64"
    return "no cuda.h and cudaTypedefs.h in #{home}/include" unless @facts.file?("#{home}/include/cuda.h") &&
                                                                    @facts.file?("#{home}/include/cudaTypedefs.h")

    rtv = @facts.cuda_rtv(header)
    return "libcudart #{rtv || "of unknown version"} is older than 12.5" if rtv.nil? || rtv.to_i < 12050

    error = @facts.value("cuda-shim-error")
    return "the shim did not build: #{error}" unless error.nil?
    unported("the shim's result (cuda-shim or cuda-shim-error) is not in the facts") if @facts.value("cuda-shim").nil?

    nil
  end

  # scripts/cuda-driver-wrap.sh, the first step after -fsyntax-only: --cuda-driver=MODE is taken out of the arguments; a
  # link that names libcuda is run again with the shim and -lcudart in its place ([:exec, ARGV]), or goes on as named
  # ([:go, ARGV]: no libcuda, mode libcuda, or a note: the shim cannot be made). --cuda-driver=cudart fails then (status 1).
  def cuda_driver_step(args)
    mode = @env_mode
    rest = []
    args.each do |a|
      if a.start_with?("--cuda-driver=") then mode = a.delete_prefix("--cuda-driver=")
      else rest << a
      end
    end
    unless ["auto", "cudart", "libcuda"].include?(mode)
      raise NfcxxExit.new("nfcxx: --cuda-driver=#{mode}: auto, cudart or libcuda", 2)
    end

    found = rest.select { |a| libcuda?(a) }.last
    return [:go, rest] if found.nil? || mode == "libcuda"

    static = rest.select { |a| cuda_static?(a) }.last
    home = cuda_toolkit(found)
    why = cuda_why(home)
    unless why.nil?
      raise NfcxxExit.new("nfcxx: --cuda-driver=cudart: #{why}", 1) if mode == "cudart"

      return [:go, rest]
    end

    lib64 = "#{home}/lib64"
    out = []
    done = false
    rest.each do |a|
      unless libcuda?(a)
        out << a
        next
      end
      next if done

      done = true
      out << @facts.value("cuda-shim")
      if static
        out << static
      else
        out.push("-L#{lib64}", "-Wl,-rpath,#{lib64}") if @facts.dir?(lib64)
        out << "-lcudart"
      end
    end
    [:exec, out]
  end

  # -E: exec g++ -E (before the backend is chosen)
  def preprocess
    args = ["-E", "-std=#{@std.delete_prefix("--")}"]
    args += ["-x", @xlang] unless @xlang.empty?
    args += @ppflags + @cflags + @sysdirs.map { |d| "-isystem#{d}" }
    @preinc.each { |f| args += ["-include", f] }
    args += @srcs
    args << "-" if @stdin_src
    args += ["-o", @out] if @outset
    emit("EXEC", "g++", *args)
    nil
  end

  # -MD/-MMD: the host preprocessor writes the dependency file (after the eccp call)
  def depend_step
    df = @dfile.empty? ? "#{strip_extension(@out)}.d" : @dfile
    tgt = @dtarget.empty? ? @out : @dtarget
    mflag = @depmode == "-MMD" ? "-MM" : "-M"
    args = [mflag]
    args << @depphony unless @depphony.empty?
    args += ["-MT", tgt, "-MF", df, "-std=#{@std.delete_prefix("--")}"]
    args += @cflags + @sysdirs.map { |d| "-isystem#{d}" } + @srcs
    emit("RUN", "g++", *args)
  end

  # ${out%.*}: the name without its last extension
  def strip_extension(name)
    dot = name.rindex(".")
    slash = name.rindex("/")
    return name if dot.nil? || (slash && dot < slash)

    name[0...dot]
  end
end

def main(argv)
  facts_arg = argv.shift.to_s
  raise ArgumentError, "the first argument is --facts=FILE" unless facts_arg.start_with?("--facts=")

  plan = Plan.new(Facts.load(facts_arg.delete_prefix("--facts=")))
  status = 0
  begin
    plan.run(argv)
  rescue PlanDone
    status = 0
  rescue NfcxxExit => e
    $stderr.write("#{e.message}\n")
    status = e.status
  end
  plan.lines.each { |line| $stdout.write("#{line}\n") }
  $stdout.write("STATUS #{status}\n")
  status
rescue NfcxxUnported => e
  $stderr.write("unported: #{e.message}\n")
  3
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
