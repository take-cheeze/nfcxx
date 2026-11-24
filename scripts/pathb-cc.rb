#!/usr/bin/env ruby
# Path B compiler: one C++ file to an object file.
#   EDG front end (lowered IL) -> typed IR (be/nfcxx_ir.c) -> QBE IL -> QBE -> assembler
#   the QBE IL is the SSA route (scripts/pathb-ssa-build) by default; --emitter=mruby selects scripts/pathb-qbe-emit.rb
#   (run by scripts/mrb.rb), and a unit the SSA route does not fully emit falls back to it with a message on stderr.
#   The mruby pipeline is what tests/pathb-qbe/run.sh validates. Hosted by default (the host g++'s C++ library headers, see scripts/host-sys.rb).
# Usage: scripts/pathb-cc.rb [options] [-std=c++NN] [-I dir | -Idir] [-Dmacro] [-Umacro] [--freestanding] file.cpp -o out.o
# This is scripts/pathb-cc (bash) ported to Ruby: the same options (see the bash script's header), the same stages in the
# same order, and the same exit statuses. The options below are what the nfcxx driver passes; each has an environment
# variable as a fallback, and the flag wins when both are given.
#   --keep=DIR, --timeout=SEC (NFCXX_PATHB_TIMEOUT, default 300; 0: no limit; a stage over it is stopped with status 124),
#   --safe-pointers, --asan, --sanitize=LIST, --ir-opt=LIST, --ir-opt-max=BYTES, --emitter=ssa|mruby, --i386, --regparm=3,
#   --m16, --pic, --no-pie, --long-double=trap, --trap-checks, --no-fp, --as-opt=OPT, --vectorize-assoc, --no-unwind, --vectorize (default on amd64 Linux with the SSA emitter), --no-vectorize, --avx2.
# Exit status: 0 done; 3 the IR has a node, type or marker the emitter refuses (reason on stderr); anything else failed.
# Needs the Path B harness (scripts/setup-pathb.sh; PATHB_CPFE, PATHB_BASE) and build/qbe/qbe (QBE).
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "host-sys"

ROOT = File.expand_path("..", File.expand_path(File.dirname($0)))
RUBY = ENV["RUBY"].to_s.empty? ? RbConfig.ruby : ENV["RUBY"]

def die(message, status = 2)
  warn message
  exit status
end

# A command run as the bash runs it under set -e: its failure ends the script with its status.
def run!(*cmd, **io)
  return if system(*cmd, **io)

  exit($?.exitstatus || 127)
end

# The status of a command, whatever it is (a killed command has 128 + the signal).
def status_of(*cmd, **io)
  return 0 if system(*cmd, **io)

  $?.exitstatus || (128 + ($?.termsig || 0))
end

# the first line of a file (empty when there is none): head -1
def first_line(path)
  return "" unless File.file?(path)

  File.readlines(path, chomp: true).first.to_s
end

# basename of the source without its extension: basename "${src%.*}"
def stem_of(src)
  File.basename(src.sub(/\.[^.]*\z/, ""))
end

qbe = ENV["QBE"].to_s.empty? ? File.join(ROOT, "build", "qbe", "qbe") : ENV["QBE"]
die("pathb-cc: no QBE at #{qbe}; run scripts/setup-qbe.sh") unless File.executable?(qbe)
qbe_target_env = ENV["PATHB_QBE_TARGET"].to_s
qbe_t = qbe_target_env.empty? ? [] : ["-t", qbe_target_env]
qbe_target = qbe_target_env.empty? ? HostSys.qbe_target : qbe_target_env

# The settings (variables are the defaults, flags override)
opts = []
src = ""
out = ""
safe_on = ENV["NFCXX_SAFE_POINTERS"] == "1" ? 1 : 0
asan_on = ENV["NFCXX_PATHB_ASAN"] == "1" ? 1 : 0
passes = "inline,hoist-pure"   # the default; --ir-opt=LIST changes it (--ir-opt=inline turns hoist-pure off, --ir-opt=none the passes)
ir_opt_max = ENV["NFCXX_IR_OPT_MAX"].to_s.empty? ? "268435456" : ENV["NFCXX_IR_OPT_MAX"]
passes_given = 0
pic = []
nopie = []
asopt = []
i386 = 0
regparm = 0
m16 = 0
emitter = ENV["NFCXX_PATHB_EMITTER"].to_s.empty? ? "ssa" : ENV["NFCXX_PATHB_EMITTER"]
nofp = 0
nounwind = 0
vectorize = nil
assoc = 0   # --vectorize-assoc: float reductions are vectorized (reassociated), qbe -F
avx2 = 0
trapchk = 0
trapimp = 0
uchar = 0
ld_trap = ((ENV["PATHB_LONG_DOUBLE"].to_s.empty? ? ENV["NFCXX_LONG_DOUBLE"].to_s : ENV["PATHB_LONG_DOUBLE"]) == "trap") ? 1 : 0
keep = ENV["PATHB_KEEP"].to_s
timeout_s = ENV["NFCXX_PATHB_TIMEOUT"].to_s.empty? ? "300" : ENV["NFCXX_PATHB_TIMEOUT"]
timeout_given = !ENV["NFCXX_PATHB_TIMEOUT"].to_s.empty?   # an explicit limit is kept for every stage (see the SSA route)
dump_opts = []
debug_on = 0   # -g: a line table (the IR's (loc ...) statements become QBE's dbgloc lines)

args = ARGV.dup
while !args.empty?
  x = args.shift
  case x
  when "-o" then out = args.shift.to_s
  when "--safe-pointers" then safe_on = 1
  when "--asan" then asan_on = 1
  when "-g", /\A-g[0-3]\z/, "-ggdb", /\A-ggdb[0-3]\z/ then debug_on = x != "-g0" && x != "-ggdb0" ? 1 : 0
  when "--no-pie" then nopie = ["--no-pie"]
  when "--i386", "--target=linux_i686" then i386 = 1
  when "--regparm=3" then regparm = 1
  when /\A--regparm=/ then die("pathb-cc: #{x}: only -mregparm=3 is supported")
  when "--m16" then m16 = 1
  when "--pic" then pic = ["--pic"]
  when /\A--sanitize=/ then dump_opts << x
  when /\A--dialect=/ then opts << x
  when /\A--diag_/ then opts << x
  when /\A--gnu[-_]version=/ then opts << x
  when /\A--ir-opt=/ then passes = x.delete_prefix("--ir-opt="); passes_given = 1
  when /\A--ir-opt-max=/ then ir_opt_max = x.delete_prefix("--ir-opt-max=")
  when /\A--emitter=/ then emitter = x.delete_prefix("--emitter=")
  when "--long-double=trap" then ld_trap = 1
  when "--trap-checks" then trapchk = 1
  when "--no-fp" then nofp = 1
  when /\A--as-opt=/ then asopt << x.delete_prefix("--as-opt=")
  when "--no-unwind" then nounwind = 1
  when "--vectorize" then vectorize = 1
  when "--no-vectorize" then vectorize = 0
  when "--vectorize-assoc" then assoc = 1
  when "--avx2" then avx2 = 1
  when "-funsigned-char", "-fno-signed-char" then uchar = 1; opts << x
  when "-fsigned-char", "-fno-unsigned-char" then uchar = 0; opts << x
  when "-nostdinc", "-ffreestanding" then trapimp = 1; opts << x
  when "-fshort-wchar" then opts << x
  when "-ftrivial-auto-var-init=zero", "-ftrivial-auto-var-init=uninitialized" then dump_opts << x
  when "-isystem", "-idirafter" then opts.push(x, args.shift.to_s)
  when /\A-isystem./, /\A-idirafter./ then opts << x
  when /\A--keep=/ then keep = x.delete_prefix("--keep=")
  when /\A--timeout=/ then timeout_s = x.delete_prefix("--timeout="); timeout_given = true
  when "-I", "-D", "-U" then opts << "#{x}#{args.shift}"
  when "--modules" then opts << "--modules"
  when "--modules_directory", "--create_module_interface" then opts.push(x, args.shift.to_s)
  when "-include" then opts.push("-include", args.shift.to_s)
  when /\A-[IDU]./, /\A-std=c\+\+/, "-std=c89", "-std=c99", "-std=c11", "-std=c17", "-std=c18", "-std=c23",
       "--freestanding", "--eh-runtime", "--cuda"
    opts << x
  when /\A-/ then nil
  else src = x
  end
end
die("pathb-cc: no input file") if src.empty?

# The 32-bit x86 target: the front end reads it as EDG's linux_i686, QBE's i386 or i386_regparm3, and a 32-bit object
cc32 = []
i386opt = []
if i386 == 1
  die("pathb-cc: --i386 needs the SSA emitter (--emitter=ssa)") unless emitter == "ssa"
  dump_opts.push("--target=linux_i686", "--freestanding")
  cc32 = ["-m32"]
  i386opt = regparm == 0 ? ["--target=i386"] : ["--target=i386_regparm3"]
  i386opt << "--m16" if m16 == 1
  pic = []
else
  die("pathb-cc: --regparm and --m16 need --i386") unless regparm == 0 && m16 == 0
end
out = "#{stem_of(src)}.o" if out.empty?

tmp = Dir.mktmpdir("pathb-cc")
at_exit { FileUtils.rm_rf(tmp) }
n = stem_of(src)
ir = File.join(tmp, "#{n}.ir")
# The checks of --asan and --safe-pointers are made on the IR as the program wrote it: the inliner is off with them unless --ir-opt asks for it
passes = "none" unless passes_given == 1 || (safe_on == 0 && asan_on == 0)
safe = []
if safe_on == 1
  safe = ["--safe"]
  dump_opts << "--ir-loc"
end
asan = []
if asan_on == 1
  asan = ["--asan"]
  dump_opts.push("--ir-loc", "--ir-scopes")
end
die("pathb-cc: --asan and --safe-pointers both replace malloc; use one") unless asan.empty? || safe.empty?
debug = []
if debug_on == 1
  debug = ["--debug-lines"]
  dump_opts << "--ir-loc" unless dump_opts.include?("--ir-loc")
end

# run a stage under --timeout (timeout(1) when it is there): its status
def tmo_status(timeout_s, *cmd, **io)
  if timeout_s != "0" && !ENV["PATH"].to_s.split(":").none? { |d| File.executable?(File.join(d, "timeout")) }
    status_of("timeout", "-k", "5", timeout_s, *cmd, **io)
  else
    status_of(*cmd, **io)
  end
end

if ENV["PATHB_IR"].to_s.empty?
  dump_opts << "--ir-noinline" if emitter == "ssa"   # the SSA route's inliner honours noinline
  frc = tmo_status(timeout_s, File.join(ROOT, "scripts", "pathb-dump.rb"), "--ir", *dump_opts, *opts, src, out: ir)
  warn("pathb-cc: #{src}: the front end ran over #{timeout_s} s (--timeout) and was stopped") if frc == 124
  exit frc unless frc == 0
else
  FileUtils.cp(ENV["PATHB_IR"], ir)   # a given IR file (tests run the emitters without the harness)
end

# -funsigned-char: the IR's plain char is renamed unsigned_char, outside the quoted names and strings
if uchar == 1
  text = File.read(ir)
  text = text.gsub(/"(?:[^"\\]|\\.)*"|(?<![\w:.$&%@])char(?!\w)/) { |m| m == "char" ? "unsigned_char" : m }
  File.write(ir, text)
end

# The IR-to-IR passes (scripts/pathb-ir-opt.rb): inline and hoist-pure (memoised pure calls in loops) by default; IR over
# --ir-opt-max is not optimized
raw = 0
if !passes.empty? && passes != "none" && passes != "off" && ENV["PATHB_IR"].to_s.empty?
  size = File.size(ir)
  if size > ir_opt_max.to_i
    warn("pathb-cc: #{src}: IR is #{size} bytes, over --ir-opt-max: not optimized")
  else
    irpasses = []
    passes.split(",").each do |p|
      irpasses << "--#{p}"
      irpasses = ["--prune-unused", "--strip-leaf-eh", *irpasses] if p == "inline"
    end
    # the inlined bodies bracket their slots with scope facts (the SSA emitter shares the slots), unless the checks keep every slot
    irpasses << "--scope-facts" if emitter == "ssa" && asan_on == 0 && safe_on == 0 && passes.include?("inline")
    # A caller over this many IR nodes takes in no more copies (pathb-ir-opt --max-caller): on Lean's generated C one function
    # grew from 3.4 MB to 14.9 MB of IR by inlining, and the SSA stage took 128 s on it, against 19 s with the cap. Smaller
    # functions are inlined as before. NFCXX_INLINE_MAX_CALLER=0 turns the cap off.
    irpasses << "--max-caller=#{ENV.fetch("NFCXX_INLINE_MAX_CALLER", "30000")}" if passes.include?("inline")
    irpasses << "--shrink-eh-frames" if passes.include?("inline")
    raw_ir = "#{ir}.raw"
    FileUtils.cp(ir, raw_ir)
    raw = 1
    opt_ir = File.join(tmp, "#{n}.opt.ir")
    if status_of(RUBY, File.join(ROOT, "scripts", "pathb-ir-opt.rb"), *irpasses, ir,
                 out: opt_ir, err: File.join(tmp, "#{n}.opt.err")).zero?
      FileUtils.mv(opt_ir, ir)
    else
      FileUtils.cp(raw_ir, ir)
      warn("pathb-cc: #{src}: the IR passes refused the unit, not optimized")
    end
  end
end

ldopt = ld_trap == 0 ? [] : ["--long-double=trap"]
ldopt << "--no-fp" if nofp != 0
ldopt << "--no-unwind" if nounwind != 0
# The loop vectorizer is on by default where its QBE pass exists: the SSA emitter on amd64 Linux (amd64_sysv only).
# --no-vectorize (driver: -fno-tree-vectorize) turns it off.
if vectorize.nil?
  vectorize = emitter == "ssa" && IO.popen(["uname", "-s"], &:read).chomp == "Linux" &&
              IO.popen(["uname", "-m"], &:read).chomp == "x86_64" ? 1 : 0
end
ldopt << "--vectorize" if vectorize != 0
die("pathb-cc: --vectorize-assoc needs --vectorize") if assoc != 0 && vectorize == 0
ldopt << "--vectorize-assoc" if assoc != 0
die("pathb-cc: --avx2 needs --vectorize") if avx2 != 0 && vectorize == 0
ldopt << "--avx2" if avx2 != 0
trapimp = 1 if nofp != 0
# --trap-checks is added when asked, or when the free-standing checks need it (the SSA emitter has the mode)
ldopt << "--trap-checks" if trapchk == 1 || (trapimp == 1 && emitter == "ssa")
if nofp == 1 || nounwind == 1 || trapchk == 1 || vectorize == 1
  die("pathb-cc: --no-fp, --no-unwind, --trap-checks and --vectorize need the SSA emitter (--emitter=ssa)") unless emitter == "ssa"
end
# The mruby emitter only: on Darwin and arm64 an extern data object is read through the GOT
emitopt = []
uname_s = IO.popen(["uname", "-s"], &:read).chomp
uname_m = IO.popen(["uname", "-m"], &:read).chomp
emitopt << "--extern-data-got" if uname_s == "Darwin" || %w[aarch64 arm64].include?(uname_m)
x87 = ENV["PATHB_X87_TARGET"].to_s.empty? ? IO.popen(["uname", "-m"], &:read).chomp : ENV["PATHB_X87_TARGET"]
emitopt << "--x87-target=#{x87}"
unless %w[ssa mruby].include?(emitter)
  die("pathb-cc: --emitter (NFCXX_PATHB_EMITTER) must be ssa or mruby, not '#{emitter}'")
end
die("pathb-cc: --asan needs the SSA emitter (--emitter=ssa)") unless asan.empty? || emitter == "ssa"

rc = 0
emit_err = File.join(tmp, "#{n}.emit")
s_path = File.join(tmp, "#{n}.s")
ssa_cmd = [File.join(ROOT, "scripts", "pathb-ssa-build"), "--qbe=#{qbe}", "-o", s_path, *i386opt, *pic, *nopie, *ldopt,
           *safe, *asan, *debug, ir]
# The SSA route's budget grows with the IR it is given: QBE with the default loop vectorizer takes about 23 s per MB of IL (a
# 17 MB unit, one large function of Lean's generated C, took 390 s), and the budget allows 40 s per MB, so a loaded machine still
# fits. Only the default limit grows; an explicit --timeout or NFCXX_PATHB_TIMEOUT stands for every stage.
ssa_timeout = timeout_given || timeout_s == "0" ? timeout_s : [timeout_s.to_i, (File.size(ir) / 25_000.0).ceil].max.to_s
if emitter == "ssa"
  rc = tmo_status(ssa_timeout, *ssa_cmd, err: emit_err)
  if rc != 0 && rc != 124 && rc != 5 && raw == 1   # the optimized IR is refused: emit the unoptimized one
    warn("pathb-cc: #{src}: the optimized IR is refused (#{first_line(emit_err)}), using the unoptimized IR")
    FileUtils.cp("#{ir}.raw", ir)
    rc = tmo_status(ssa_timeout, *ssa_cmd, err: emit_err)
  end
  if rc != 0
    # a function outside the SSA route's subset refuses the unit (no fallback to the mruby emitter)
    if rc == 124
      warn("pathb-cc: #{src}: SSA route: ran over #{ssa_timeout} s (--timeout) and was stopped")
    else
      warn("pathb-cc: #{src}: SSA route: #{first_line(emit_err)}")
    end
    unless keep.empty?
      FileUtils.mkdir_p(keep)
      FileUtils.cp(ir, keep)
    end
    exit rc
  end
end

if emitter == "mruby"
  ssa = File.join(tmp, "#{n}.ssa")
  rc = status_of(File.join(ROOT, "scripts", "mrb.rb"), File.join(ROOT, "scripts", "pathb-qbe-emit.rb"), *ldopt, *emitopt, *safe, ir,
                 out: ssa, err: emit_err)
  if rc != 0
    warn("pathb-cc: #{src}: #{first_line(emit_err)}")
    unless keep.empty?
      FileUtils.mkdir_p(keep)
      FileUtils.cp(ir, keep)
    end
    exit rc
  end
  run!(qbe, *qbe_t, ssa, out: s_path)
  # QBE has no weak linkage: .weak for the IR's (weak) definitions
  aw_err = File.join(tmp, "#{n}.aw")
  rc = status_of(File.join(ROOT, "scripts", "mrb.rb"), File.join(ROOT, "scripts", "pathb-qbe-emit.rb"), "--append-weak", ssa, s_path,
                 qbe_target, err: aw_err)
  if rc != 0
    warn("pathb-cc: #{src}: #{first_line(aw_err)}")
    unless keep.empty?
      FileUtils.mkdir_p(keep)
      FileUtils.cp(ir, keep)
    end
    exit rc
  end
end

unless keep.empty?
  FileUtils.mkdir_p(keep)
  FileUtils.cp([ir, s_path], keep)
  ssa = File.join(tmp, "#{n}.ssa")
  FileUtils.cp(ssa, keep) if File.file?(ssa)
end

if !ENV["NFCXX_GCC"].to_s.empty?
  # cosmocc does not take assembly input; the QBE output is x86_64 ELF, as gcc-cc does (--cosmo)
  run!("as", *asopt, "-o", out, s_path)
else
  asw = asopt.map { |x| "-Wa,#{x}" }
  run!("cc", *cc32, "-c", *asw, "-o", out, s_path)
end
