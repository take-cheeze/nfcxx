#!/usr/bin/env ruby
# nfcxx's argument loop, ported from the bash in nfcxx (the "while [ $# -gt 0 ]" loop after its setup). The first slice
# covers the loop itself with the default environment (no NFCXX_* variables): the options set the state below, and an
# error exits 2 with nfcxx's message. Checked against the bash by tests/nfcxx/loop-state.sh, which runs nfcxx's own setup
# and loop with the build step (ensure_tool) stubbed out (tests/nfcxx/option-state.sh).
#
# Not covered in this slice (refused as "unported", exit 3): the -fsyntax-only re-run, --bundle- and --cuda-driver (their
# wrappers run the driver again), -fuse-ld= (which asks the shell whether ld.NAME exists; the port takes that as --ld-available=),
# and every NFCXX_* variable (the defaults here are the ones with no variable set).
#
#   ruby scripts/nfcxx-loop.rb ARG...   prints the state the loop leaves, one line per variable
#   --ld-available=NAME,...             the ld.NAME programs that exist (for -fuse-ld=NAME)

class NfcxxUnported < StandardError
end

class NfcxxExit < StandardError
  attr_reader :status
  def initialize(message, status)
    super(message)
    @status = status
  end
end

# The state of the loop (the bash globals of the same names).
class LoopState
  attr_accessor :std, :out, :outset, :emit_c, :emit_hip, :backend, :backend_explicit, :path_b, :ir_opt, :ir_opt_set
  attr_accessor :eh_unwind_on, :eh_shim_on, :cache_dir, :cache_log_file, :keep_intermediates, :time_log, :instantiate
  attr_accessor :promote_slots, :unroll, :struct_slots, :pathb_c, :ld_name, :obfuscate, :dialect, :dialect_asked
  attr_accessor :gnu, :gnu_user, :freestanding, :cosmo, :target, :trace, :moddir, :asan, :safeptr, :sanitize
  attr_accessor :shared, :pic, :rdynamic, :compile_only, :pthread, :preprocess, :xlang, :stdin_src
  attr_accessor :depmode, :dfile, :dtarget, :depphony, :ncpp, :nobj
  attr_reader :files, :cflags, :cfiles, :cu_inputs, :cpp2_inputs, :srcs, :ppflags, :pie_opts, :preinc, :sysdirs
  attr_reader :isa, :diag_opts, :asanopts

  def initialize
    @std = "--c++23"
    @out = "a.out"
    @outset = 0
    @emit_c = 0
    @emit_hip = ""
    @backend = ""
    @backend_explicit = 0
    @path_b = 0
    @ir_opt = ""
    @ir_opt_set = 0
    @eh_unwind_on = 0
    @eh_shim_on = 1
    @cache_dir = ""
    @cache_log_file = ""
    @keep_intermediates = 0
    @time_log = ""
    @instantiate = "used"
    @promote_slots = 1
    @unroll = 1
    @struct_slots = 1
    @pathb_c = ""
    @ld_name = ""
    @obfuscate = 0
    @dialect = "g++"
    @dialect_asked = ""
    @gnu = ""
    @gnu_user = ""
    @freestanding = 0
    @cosmo = 0
    @target = ""
    @trace = ""
    @moddir = ""
    @asan = 0
    @safeptr = 0
    @sanitize = ""
    @shared = 0
    @pic = 0
    @rdynamic = 0
    @compile_only = 0
    @pthread = 0
    @preprocess = 0
    @xlang = ""
    @stdin_src = 0
    @depmode = ""
    @dfile = ""
    @dtarget = ""
    @depphony = ""
    @ncpp = 0
    @nobj = 0
    @files = []
    @cflags = []
    @cfiles = []
    @cu_inputs = []
    @cpp2_inputs = []
    @srcs = []
    @ppflags = []
    @pie_opts = []
    @preinc = []
    @sysdirs = []
    @isa = []
    @diag_opts = []
    @asanopts = []
  end
end

def onoff(flag, value)
  return 1 if value == "on" || value == "1"
  return 0 if value == "off" || value == "0"

  raise NfcxxExit.new("nfcxx: #{flag} takes on or off (got '#{value}')", 2)
end

def starts_with?(text, prefix)
  text.start_with?(prefix)
end

# The loop. args are the arguments after the setup's own set -- (no wrapper has changed them).
def run_loop(args, state, ld_available)
  i = 0
  n = args.length
  while i < n
    a = args[i]
    if a == "--emit-c" then state.emit_c = 1
    elsif a == "--emit-hip" then state.emit_hip = 1
    elsif starts_with?(a, "--backend=")
      state.backend = a[10..]
      state.backend_explicit = 1
      state.path_b = 1 if state.backend == "pathb"
    elsif starts_with?(a, "--ir-opt=")
      state.ir_opt = a[9..]
      state.ir_opt_set = 1
    elsif a == "--eh-unwind" then state.eh_unwind_on = 1
    elsif a == "--no-eh-unwind" then state.eh_unwind_on = 0
    elsif a == "--no-eh-shim" then state.eh_shim_on = 0
    elsif starts_with?(a, "--cache-log=") then state.cache_log_file = a[12..]
    elsif starts_with?(a, "--cache=") then state.cache_dir = a[8..]
    elsif a == "--keep-intermediates" then state.keep_intermediates = 1
    elsif starts_with?(a, "--time-log=") then state.time_log = a[11..]
    elsif starts_with?(a, "--instantiate=") then state.instantiate = a[14..]
    elsif starts_with?(a, "--promote-slots=") then state.promote_slots = onoff("--promote-slots", a[16..])
    elsif starts_with?(a, "--unroll=") then state.unroll = onoff("--unroll", a[9..])
    elsif starts_with?(a, "--struct-slots=") then state.struct_slots = onoff("--struct-slots", a[15..])
    elsif starts_with?(a, "--pathb-c=") then state.pathb_c = a[10..]
    elsif starts_with?(a, "-fuse-ld=")
      name = a[9..]
      if ld_available.include?(name)
        state.ld_name = name
      else
        state.files << a
      end
    elsif a == "--obfuscate-kernels" then state.obfuscate = 1
    elsif a == "-fsanitize=address" then state.asan = 1
    elsif a == "-fsafe-pointers" then state.safeptr = 1
    elsif a == "-fno-safe-pointers" then state.safeptr = 0
    elsif a == "-fno-sanitize=address" then state.asan = 0
    elsif starts_with?(a, "-fsanitize=") || starts_with?(a, "-fsanitize-")
      raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=address; docs/notes/asan.md)", 2)
    elsif a == "-fno-omit-frame-pointer" || a == "-fomit-frame-pointer" then state.asanopts << a
    elsif starts_with?(a, "--dialect=")
      state.dialect = a[10..]
      state.dialect_asked = 1
    elsif starts_with?(a, "--gnu-version=")
      state.gnu = a[14..]
      state.gnu_user = state.gnu
    elsif a == "--freestanding" then state.freestanding = 1
    elsif a == "--cosmo" then state.cosmo = 1
    elsif starts_with?(a, "--target=") then state.target = a[9..]
    elsif starts_with?(a, "--trace=") then state.trace = a[8..]
    elsif starts_with?(a, "--module-dir=") then state.moddir = a[13..]
    elsif a == "-shared"
      state.shared = 1
      state.pic = 1
    elsif a == "-fPIC" || a == "-fpic" then state.pic = 1
    elsif a == "-rdynamic" then state.rdynamic = 1
    elsif a == "-c"
      state.compile_only = 1
      state.files << "-c"
    elsif a == "-o"
      state.out = args[i + 1].to_s
      state.outset = 1
      i += 1
    elsif starts_with?(a, "-std=c++") then state.std = "--c++#{a[8..]}"
    elsif starts_with?(a, "-std=gnu++") then state.std = "--c++#{a[10..]}"
    elsif a == "-E" then state.preprocess = 1
    elsif a == "-P" then state.ppflags << "-P"
    elsif a == "-x"
      state.xlang = args[i + 1].to_s
      i += 1
    elsif a == "-" then state.stdin_src = 1
    elsif a == "-pthread" then state.pthread = 1
    elsif a == "-fexceptions" || a == "-fwrapv" || a == "-fno-strict-aliasing" then nil
    elsif a == "-fno-sanitize=all" then state.sanitize = ""
    elsif starts_with?(a, "-fno-sanitize=") || starts_with?(a, "-fsanitize-")
      raise NfcxxExit.new("nfcxx: #{a} is not supported (only -fsanitize=undefined and its checks, docs/notes/ubsan.md)", 2)
    elsif a == "-pipe" then nil
    elsif a == "-fvisibility-inlines-hidden" || starts_with?(a, "-fvisibility=") then nil
    elsif a == "-fPIE" || a == "-fpie"
      state.pie_opts << "--c_to_obj_option" << "-fPIE"
    elsif a == "-pie"
      state.pie_opts << "--c_to_obj_option" << "-pie"
    elsif starts_with?(a, "-Wl,") then state.files << a
    elsif starts_with?(a, "-l") && a.length > 2 then state.files << a
    elsif a == "-Wno-narrowing" then state.diag_opts << "--diag_warning=narrowing_conversion"
    elsif starts_with?(a, "-W") || a == "-w" then nil
    elsif starts_with?(a, "-m") then state.isa << a
    elsif a == "-MD" || a == "-MMD" then state.depmode = a
    elsif a == "-MP" then state.depphony = "-MP"
    elsif a == "-MF"
      state.dfile = args[i + 1].to_s
      i += 1
    elsif a == "-MT" || a == "-MQ"
      state.dtarget = args[i + 1].to_s
      i += 1
    elsif a == "-include"
      state.preinc << args[i + 1].to_s
      i += 1
    elsif a == "-isystem"
      state.sysdirs << args[i + 1].to_s
      i += 1
    elsif starts_with?(a, "-isystem") && a.length > 8 then state.sysdirs << a[8..]
    elsif a.end_with?(".c") then state.cfiles << a
    elsif (starts_with?(a, "-I") || starts_with?(a, "-D") || starts_with?(a, "-U")) && a.length > 2
      state.cflags << a
      state.files << a
    elsif a == "-I" || a == "-D" || a == "-U"
      raise NfcxxExit.new("nfcxx: #{a} needs an argument", 2) unless i + 1 < n

      state.cflags << "#{a}#{args[i + 1]}"
      state.files << "#{a}#{args[i + 1]}"
      i += 1
    elsif a.end_with?(".o")
      state.files << a
      state.nobj += 1
    elsif starts_with?(a, "-") || a.end_with?(".a") || a.end_with?(".so")
      state.files << a
    elsif a.end_with?(".cu")
      state.cu_inputs << a
      state.files << a
      state.ncpp += 1
      state.srcs << a
    elsif a.end_with?(".cpp2")
      state.cpp2_inputs << a
      state.files << a
      state.ncpp += 1
      state.srcs << a
    else
      state.files << a
      state.ncpp += 1
      state.srcs << a
    end
    i += 1
  end
  state
end

def emit(state)
  scalars = %w[std out outset emit_c emit_hip backend backend_explicit path_b ir_opt ir_opt_set eh_unwind_on eh_shim_on
               cache_dir cache_log_file keep_intermediates time_log instantiate promote_slots unroll struct_slots pathb_c
               ld_name obfuscate dialect dialect_asked gnu gnu_user freestanding cosmo target trace moddir asan safeptr
               sanitize shared pic rdynamic compile_only pthread preprocess xlang stdin_src depmode dfile dtarget depphony
               ncpp nobj]
  scalars.each { |name| $stdout.write("#{name}=#{state.public_send(name)}\n") }
  %w[files cflags cfiles cu_inputs cpp2_inputs srcs ppflags pie_opts preinc sysdirs isa diag_opts asanopts].each do |name|
    state.public_send(name).each { |x| $stdout.write("#{name}+=#{x}\n") }
  end
end

def main(argv)
  ld_available = []
  if argv.first && argv.first.start_with?("--ld-available=")
    ld_available = argv.shift[15..].split(",")
  end
  argv.each do |a|
    if a == "-fsyntax-only" || a.start_with?("--bundle-") || a.start_with?("--cuda-driver=")
      raise NfcxxUnported, a
    end
  end
  state = run_loop(argv, LoopState.new, ld_available)
  emit(state)
  0
rescue NfcxxExit => e
  $stdout.flush
  $stderr.write("#{e.message}\n")
  e.status
rescue NfcxxUnported => e
  $stdout.flush
  $stderr.write("unported: #{e.message}\n")
  3
end

rc = main(ARGV)
exit(rc) if rc != 0
