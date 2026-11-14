#!/usr/bin/env ruby
# nfcxx's driver for --target=linux_k1om, ported from the bash in nfcxx: the argument checks, the commands the k1om
# build runs (the k1om GCC through scripts/k1om-cc, EDG's eccp, the EDG front end for --emit-c) and the -E line, which
# runs the host g++ whatever the target. See docs/notes/k1om.md.
#
#   ruby scripts/nfcxx-k1om.rb --facts=FILE ARG...
#
# Prints the commands the bash runs, in its order, then "STATUS n" (the status the bash ends with):
#   RUN NAME ARG...   a command the bash runs (the EDG driver, the front end, the k1om GCC, the host g++ for -E)
#   CP SRC DST        a copy (-c of C sources)
#   ENV NAME=VALUE    a variable the EDG driver or front end is run with, when the bash exports or inherits it
# A refusal the bash makes (status 2) prints the lines before it and "STATUS 2" (the message is on stderr). An argument
# list the port does not cover exits 3 with "unported: ..." on stderr and prints nothing: the bash must not refuse it.
#
# Accepted options: --freestanding, --emit-c, --backend=NAME, --target=NAME (the last one wins), --dialect=g++|clang,
# --gnu-version=N, --instantiate=auto|used, --keep-intermediates, --no-eh-unwind, --no-eh-shim, -c, -o FILE, -E,
# -std=c++NN|gnu++NN, -DX, -UX (also -D X, -U X), -WX, -w, -pipe, -O[0-3s], -g, -fwrapv, -fexceptions,
# -fno-strict-aliasing, -pthread, -fsanitize=address, -fno-sanitize=address, -fno-sanitize=all, -fno-omit-frame-pointer,
# -fomit-frame-pointer, -fsafe-pointers, -fno-safe-pointers, -Wno-narrowing, -lNAME (not cuda), -IDIR.
# Inputs: .cc, .cpp, .cxx sources, .c sources, .o objects, .a and .so (link inputs, not counted as inputs).
# Refused by the bash at parse time (status 2): -fsanitize=CHECK other than address, -fno-sanitize=CHECK other than
# address and all, -fsanitize-*, and -D, -U, -I without an argument; -fsafe-pointers refuses in the build (not --emit-c).
# Refused as unported (the bash may do something the port does not model): every other option and input (-x, -P, -MD,
# -include, -isystem, -m*, -shared, -fPIC, -rdynamic, -Wl,, -fuse-ld, --cache, --trace, --time-log, --cosmo,
# --eh-unwind, --ir-opt, inputs other than the listed suffixes, such as .s), the no-target builds that are not --emit-c of a
# freestanding program (Path B by default, and the host's include directories), the other EDG targets past their gate,
# and -c of one source with a -I directory (the SYCL pre-pass reads the -I directories and the source).
#
# FILE holds the facts the bash reads from the machine (tests/nfcxx-k1om/run.sh writes it):
#   root DIR             the repository root (the bash's $root)
#   cwd DIR              the directory the bash runs in; names without a directory are printed under it
#   k1om-root DIR        NFCXX_K1OM_ROOT as the bash sees it (the harness sets it)
#   eccp 0|1             ${EDG}/eccp is executable (scripts/setup-edg.sh built the EDG driver)
#   k1om-gcc 0|1         $NFCXX_K1OM_ROOT/bin/k1om-mpss-linux-gcc is executable
#   k1om-libc 0|1        ROOT/build/k1om/libC.a is a file (scripts/setup-k1om.sh)
#   eh-tls 0|1           ROOT/build/edg/eh-tls exists (the EDG runtime has per-thread EH state)
#   edg-table NAME       ROOT/build/edg-base/lib_NAME is a directory (one line per table)
#   module PATH          PATH declares or imports a C++ module (the module check reads the source; not ported)
#
# Assumed, not read: the host is Linux, and its g++ is GCC 13 (not clang), so the dialect is g++ and host_clang_version
# prints nothing; NFCXX_* variables other than NFCXX_K1OM_ROOT are unset; the k1om GCC's --version is not clang; the
# temporary directories the bash makes are printed as TMP (mktemp's names are not modelled).

require "pathname"

class NfcxxUnported < StandardError
end

# a refusal the bash makes: its message, and its status
class NfcxxExit < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end

def unported(what)
  raise NfcxxUnported, what
end

def refuse(message)
  raise NfcxxExit.new("nfcxx: #{message}", 2)
end

class Facts
  attr_reader :tables, :modules

  def initialize(values, tables, modules)
    @values = values
    @tables = tables
    @modules = modules
  end

  def self.load(path)
    values = {}
    tables = []
    modules = []
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")

      key, rest = line.split(" ", 2)
      case key
      when "edg-table" then tables << rest.to_s
      when "module" then modules << Pathname.new(rest.to_s).cleanpath.to_s
      else values[key] = rest.to_s
      end
    end
    new(values, tables, modules)
  end

  def flag?(key)
    @values[key] == "1"
  end

  def value(key)
    @values.fetch(key) { unported("fact #{key} is not given") }
  end
end

class Driver
  attr_reader :lines

  def initialize(facts)
    @facts = facts
    @lines = []
    @std = "--c++23"
    @dialect = "g++"
    @freestanding = false
    @emit_c = false
    @backend = nil
    @backend_explicit = false
    @target = ""
    @gnu = nil
    @out = "a.out"
    @outset = false
    @compile_only = false
    @preprocess = false
    @asan = false
    @asanopts = []
    @safeptr = false
    @pthread = false
    @instantiate = "used"
    @diag = []
    @files = []   # the bash's files: options and inputs in argument order
    @cflags = []  # -I, -D and -U, as given
    @srcs = []
    @cfiles = []
    @nobj = 0
    @k1om = false
  end

  def run(argv)
    parse(argv)
    refuse("no input files") if @srcs.size + @nobj + @cfiles.size == 0
    if @compile_only && @srcs.size == 1 && @nobj == 0 && @cfiles.empty? && !@preprocess && !@emit_c &&
       @cflags.any? { |f| f.start_with?("-I") }
      unported("-c of one source with -I: the SYCL pre-pass depends on the -I directories and the source's includes")
    end
    return preprocess if @preprocess

    refuse("EDG not built; run scripts/setup-edg.sh") if needs_eccp? && !@facts.flag?("eccp")
    refuse("--instantiate (NFCXX_INSTANTIATE) is auto or used (got #{@instantiate})") unless %w[auto used].include?(@instantiate)
    @srcs.each do |s|
      unported("#{s} declares or imports a module (not ported)") if @facts.modules.include?(Pathname.new(s).cleanpath.to_s)
    end
    if @target == "linux_k1om"
      k1om_gate
    elsif !@target.empty?
      other_target_gate
    end
    if @emit_c
      refuse("--emit-c does not apply to .c inputs (they skip the front end)") unless @cfiles.empty?
      unported("--emit-c without a source") if @srcs.empty?
      unless @k1om || (@target.empty? && @freestanding && !@asan)
        unported("--emit-c on the host (no --target, no --freestanding): the host's include directories and GNU version")
      end
      return emit_c
    end
    unported("no --target: the default backend (Path B) and the host build are not ported") unless @k1om
    refuse("-fsafe-pointers needs Path B, which compiles hosted programs only") if @safeptr
    build
  end

  private

  def parse(argv)
    i = 0
    while i < argv.size
      a = argv[i]
      case a
      when "--emit-c" then @emit_c = true
      when "--freestanding" then @freestanding = true
      when /\A--backend=(.*)\z/
        @backend = Regexp.last_match(1)
        @backend_explicit = true
      when "--no-eh-unwind", "--no-eh-shim", "--keep-intermediates" then nil
      when /\A--instantiate=(.*)\z/ then @instantiate = Regexp.last_match(1)
      when /\A--dialect=(g\+\+|clang)\z/ then @dialect = Regexp.last_match(1)
      when /\A--gnu-version=(\d+)\z/ then @gnu = Regexp.last_match(1)
      when /\A--target=(.*)\z/ then @target = Regexp.last_match(1)
      when "-fsanitize=address" then @asan = true
      when "-fno-sanitize=address" then @asan = false
      when "-fno-sanitize=all" then nil
      when /\A-fsanitize[=-]/, /\A-fno-sanitize=/ then refuse("#{a} is not supported")
      when "-fsafe-pointers" then @safeptr = true
      when "-fno-safe-pointers" then @safeptr = false
      when "-fno-omit-frame-pointer", "-fomit-frame-pointer" then @asanopts << a
      when "-c"
        @compile_only = true
        @files << a
      when "-o"
        unported("-o without a file") if i + 1 >= argv.size
        @out = argv[i + 1]
        @outset = true
        i += 1
      when /\A-std=c\+\+(.*)\z/, /\A-std=gnu\+\+(.*)\z/
        @std = "--c++#{Regexp.last_match(1)}"
      when "-E" then @preprocess = true
      when "-pthread" then @pthread = true
      when "-fexceptions", "-fwrapv", "-fno-strict-aliasing", "-pipe", "-w" then nil
      when "-Wno-narrowing" then @diag << "--diag_warning=narrowing_conversion"
      when /\A-W/ then nil
      when "-I", "-D", "-U"
        refuse("#{a} needs an argument") if i + 1 >= argv.size
        @cflags << a + argv[i + 1]
        @files << a + argv[i + 1]
        i += 1
      when /\A-[IDU]./
        @cflags << a
        @files << a
      when /\A-O[0-3s]?\z/, "-g" then @files << a
      when /\A-l(.+)\z/
        unported("-l of cuda") if Regexp.last_match(1).include?("cuda")
        @files << a
      when /\A.+\.o\z/
        @files << a
        @nobj += 1
      when /\A.+\.(a|so)\z/ then @files << a
      when /\A.+\.(cc|cpp|cxx)\z/
        @files << a
        @srcs << a
      when /\A.+\.c\z/ then @cfiles << a
      else
        unported("option or input #{a}")
      end
      i += 1
    end
  end

  def needs_eccp?
    !@srcs.empty? || @emit_c || (@nobj > 0 && @cfiles.empty?)
  end

  def other_target_gate
    refuse("--target needs --freestanding (the host's library headers are the host target's)") unless @freestanding
    refuse("--target needs --emit-c (the generated C is for the target; compile it with a cross compiler)") unless @emit_c
    refuse("no EDG target '#{@target}' (lib_* tables: #{@facts.tables.join(' ')})") unless @facts.tables.include?(@target)
    unported("EDG target #{@target} passes the gate; its --emit-c front-end run is not ported")
  end

  def k1om_gate
    refuse("--target=linux_k1om needs --freestanding (the host's C++ headers are GCC 13's, not k1om's)") unless @freestanding
    refuse("--target=linux_k1om uses the gcc backend (the k1om GCC)") if @backend_explicit && @backend != "gcc"
    refuse("no k1om toolchain at #{k1om_root} (NFCXX_K1OM_ROOT; docs/notes/k1om.md)") unless @facts.flag?("k1om-gcc")
    refuse("no k1om runtime at #{root}/build/k1om/libC.a (run scripts/setup-k1om.sh)") unless @facts.flag?("k1om-libc")
    @backend = "gcc"
    @k1om = true
  end

  # the commands of the gcc backend for a program (the k1om GCC's C compiles, the EDG driver's compile and link)
  def build
    asan_c = @asan ? ["-fsanitize=address", "-fno-omit-frame-pointer", *@asanopts] : []
    cobjs = []
    unless @cfiles.empty?
      @cfiles.each_with_index do |c, n|
        o = "TMP/#{n}.o"
        k1om_cc(["-c", "-O2", "-fwrapv", "-fno-strict-aliasing", *asan_c, *@cflags, c, "-o", o])
        cobjs << o
      end
      if @compile_only && @srcs.empty?
        refuse("-c with -o needs exactly one source") if @outset && cobjs.size != 1
        @cfiles.each_with_index do |c, i|
          dst = @outset ? @out : "#{File.basename(c, '.c')}.o"
          @lines << "CP #{cobjs[i]} #{dst}"
        end
        return
      end
      if @srcs.empty? && (@nobj.zero? || !@facts.flag?("eccp"))
        k1om_cc([*asan_c, *cobjs, *@files, "-o", @out])
        return
      end
    end
    k1om_cc(["--version"]) # the probe for clang: prints nothing here, so the gcc path keeps -fkeep-static-functions
    eccp(asan_c, cobjs)
  end

  def eccp(asan_c, cobjs)
    moves = !@compile_only
    userinc = []
    eflist = []
    @files.each do |f|
      case f
      when /\A-I(.+)\z/
        userinc << (moves ? "-I#{abs(Regexp.last_match(1))}" : f)
      when /\A-l(.+)\z/
        eflist << "--c_to_obj_lib=#{Regexp.last_match(1)}"
      else
        eflist << ecp_arg(f, moves)
      end
    end
    picopts = []
    picopts += ["--c_to_obj_option", "-pthread"] if @pthread
    asan_c.each { |o| picopts += ["--c_to_obj_option", o] }
    argv = [@std, "--#{@dialect}", "--wdir", "/", "--no_standard_includes", "-I#{root}/lib"]
    argv += inst_opts
    argv += @diag
    argv += userinc
    argv += %w[--c_to_obj_option -O2 --c_to_obj_option -fwrapv --c_to_obj_option -fno-strict-aliasing]
    argv += %w[--c_to_obj_option -fkeep-static-functions]
    argv += eh_tls
    argv += %w[--c_to_obj_option -fgnu89-inline]
    argv += picopts
    argv += cobjs
    argv += eflist
    # -c without -o: the object is <stem>.o (eccp makes one object per call; nfcxx takes a single source, since #1137)
    out = @compile_only && !@outset ? "#{File.basename(@srcs[0].to_s, ".*")}.o" : @out
    argv += ["-o", ecp_arg(out, moves)]
    run_cmd("eccp", argv)
    env_lines(eccp: true)
  end

  def emit_c
    inc = ["-I#{root}/lib"]
    @files.each { |f| inc.unshift("-I#{abs(Regexp.last_match(1))}") if f =~ /\A-I(.+)\z/ }
    argv = ["-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", @std, "--#{@dialect}", *eh_tls, *gnu_opts, *@diag, *inc,
            "--gen_c_file_name=TMP/out.c", abs(@srcs[0])]
    run_cmd("cpfe", argv)
    env_lines(eccp: false)
  end

  def preprocess
    args = ["-E", "-std=#{@std.delete_prefix('--')}", *@cflags, *@srcs]
    args += ["-o", @out] if @outset
    run_cmd("g++", args)
  end

  # the k1om GCC through scripts/k1om-cc: its own mapping of the options, then -L of the runtime when it links
  def k1om_cc(args)
    link = args.none? { |a| %w[-c -E -S].include?(a) }
    out = []
    args.each do |a|
      case a
      when "-std=gnu17" then a = "-std=gnu1x"
      when "-std=c17", "-std=c18" then a = "-std=c1x"
      when "-fdiagnostics-plain-output", "-fkeep-static-functions" then next
      end
      next if link && File.fnmatch?("*build/edg/lib*", a)

      out << a
    end
    out << "-L#{root}/build/k1om" if link
    run_cmd("k1om-gcc", ["-B#{root}/scripts/k1om-bin/", *out])
  end

  def gnu_opts
    return [] if @dialect == "clang"

    ["--gnu_version=#{@gnu || '130000'}"]
  end

  def inst_opts
    return [] unless @instantiate == "used"

    %w[--no_auto_instantiation -tused --c_to_obj_option -ffunction-sections --c_to_obj_option -fdata-sections
       --c_to_obj_option -Wl,--gc-sections]
  end

  def eh_tls
    @facts.flag?("eh-tls") ? ["--nfcxx_eh_thread_local"] : []
  end

  # the variables the bash exports (or the harness gives it) that the EDG driver and front end inherit
  def env_lines(eccp:)
    @lines << "ENV EDG_CPFE_DEFAULT_OPTIONS=#{gnu_opts.join(' ')} " unless gnu_opts.empty?
    @lines << "ENV NFCXX_AS=#{root}/scripts/k1om-bin/as" if @k1om
    @lines << "ENV NFCXX_CC=#{root}/scripts/gcc-cc" if eccp
    @lines << "ENV NFCXX_GCC=#{root}/scripts/k1om-cc" if @k1om
    @lines << "ENV NFCXX_K1OM_ROOT=#{k1om_root}"
  end

  def run_cmd(name, args)
    @lines << "RUN #{name} #{args.join(' ')}"
  end

  def ecp_arg(arg, moves)
    return arg if arg.start_with?("-") || !moves

    abs(arg)
  end

  # abs_path of a name: the directory is the working directory when the name has none (a name with a directory
  # needs the directory to exist, which the port does not read)
  def abs(name)
    unported("#{name}: a path with a directory (abs_path needs the directory)") if name.include?("/")
    "#{cwd}/#{name}"
  end

  def root
    @facts.value("root")
  end

  def cwd
    @facts.value("cwd")
  end

  def k1om_root
    @facts.value("k1om-root")
  end
end

def main(argv)
  facts_arg = argv.shift.to_s
  raise ArgumentError, "the first argument is --facts=FILE" unless facts_arg.start_with?("--facts=")

  driver = Driver.new(Facts.load(facts_arg.delete_prefix("--facts=")))
  status = 0
  begin
    driver.run(argv)
  rescue NfcxxExit => e
    $stderr.write("#{e.message}\n")
    status = e.status
  end
  $stdout.write(driver.lines.map { |l| "#{l}\n" }.join + "STATUS #{status}\n")
  status
rescue NfcxxUnported => e
  $stderr.write("unported: #{e.message}\n")
  3
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
