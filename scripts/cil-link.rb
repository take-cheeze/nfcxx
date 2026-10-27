# cil-link.rb: link qbe2cil.rb / pathb-cil-emit.rb fragments into one CIL executable (the nfcc `cil` backend;
# docs/notes/cil.md). Port of tests/mruby/oracle/cil-link.py, which writes the same CIL text and the same launcher.
#
#   scripts/mrb scripts/cil-link.rb [--ilasm PATH] [--cc CC] [--keep-il] -o OUT FRAGMENT...
#
# The mruby interpreter has no ENV, so the Python original's environment variables are arguments:
# ILASM -> --ilasm (default build/cil/ilasm beside scripts/), CC -> --cc (default cc, for the variadic call shim),
# NFCXX_KEEP_IL -> --keep-il (also write OUT.il, the CIL text).
#
# Writes OUT (a shell launcher), OUT.dll and OUT.runtimeconfig.json. Run with `dotnet OUT.dll` or OUT.
# Everything lives in one static class `Prog`: functions are methods, global symbols are static fields `addr_<name>`
# holding the address (int64), and Init() allocates the data, fills it in and runs the constructors. Calls to a
# function no unit defines become P/Invoke stubs (libc.so.6, or libm.so.6 for the math functions). Data no unit
# defines is found with dlsym at Init. The entry point calls Init, builds argv = {"<program>", NULL}, and calls main.
#
# mruby has no Regexp and no Process: the fragments are read with JSON.parse (mruby-json), which turns an integer
# above 2**63 - 1 into a Float (a float64 with the sign bit set is such an integer, as its bit pattern). Those integers
# are quoted before the parse and turned back into Integers after it (quote_big_ints, restore_big_ints). ilasm and the
# C compiler run through IO.popen with the shell's exit status read back from `echo $?`.

LIBM = %w[sqrt sin cos tan asin acos atan atan2 exp exp2 log log2 log10 pow
          floor ceil round trunc fmod fabs hypot cbrt sinh cosh tanh fmin fmax
          copysign ldexp frexp modf sqrtf sinf cosf powf fabsf floorf ceilf roundf
          fmodf expf logf]
NOOP_INTRINSICS = %w[__nfcxx_fence __nfcxx_int3] # the x86 fence and int3 stubs of qbe-prep (no CIL form)
NUMERIC_KINDS = %w[int8 int16 int32 int64 float32 float64]
RUNTIME = "8.0.0"

# name, IL return type, parameter IL types, body: the runtime of the C++ exceptions on CIL (in the Python dict's order).
CXX_RUNTIME = [
  ["_setjmp", "int32", ["int64"], ["ldc.i4.0", "ret"]],
  ["__throw_setup", "int64", ["int64", "int64", "int32"],
   ["ldc.i8 1", "ldarg.1", "call int64 Prog::'calloc'(int64, int64)", "dup", "stsfld int64 Prog::'cxx_ptr'", "ret"]],
  ["__throw", "void", [], ["newobj instance void class CxxThrow::.ctor()", "throw"]],
  ["__rethrow", "void", [], ["newobj instance void class CxxThrow::.ctor()", "throw"]],
  ["__exception_caught", "void", [], ["ret"]],
  ["__destroy_exception_object", "void", [], ["ret"]],
]

SHIM_C = <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
/* Calls the named function through a variadic prototype, so the SysV ABI sees the vector registers in use (%al). */
typedef long (*nfcxx_vfn)(long, long, long, long, long, long, ...);
long nfcxx_vcall(const char *name, long i0, long i1, long i2, long i3, long i4, long i5,
                 double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7,
                 long s0, long s1, long s2, long s3, long s4, long s5, long s6, long s7) {
    nfcxx_vfn fn = (nfcxx_vfn)dlsym(RTLD_DEFAULT, name);
    return fn(i0, i1, i2, i3, i4, i5, d0, d1, d2, d3, d4, d5, d6, d7, s0, s1, s2, s3, s4, s5, s6, s7);
}
C

def die(msg)
  $stderr.puts("cil-link: #{msg}")
  exit 1
end

# Python's repr of a list of strings, for the one message that prints one.
def py_list(items)
  "[" + items.map { |s| "'#{s}'" }.join(", ") + "]"
end

def sig_str(sig)
  "#{sig['ret']}(#{sig['params'].join(', ')})"
end

# Every ' in a symbol name becomes \' (Python's name.replace("'", "\\'")).
def qname(name)
  name.gsub("'") { "\\'" }
end

# The last component, as os.path.basename (a trailing slash gives "").
def basename(path)
  parts = path.split("/", -1)
  parts.last || ""
end

# len() of a UTF-8 string: the characters, not the bytes.
def char_len(s)
  s.bytes.count { |b| (b & 0xc0) != 0x80 }
end

# The little-endian bytes of a non-negative integer (to_bytes(width, 'little')).
def le_bytes(v, width)
  out = []
  width.times do
    out << (v & 0xff)
    v = v >> 8
  end
  out
end

def sh_quote(s)
  "'" + s.gsub("'") { "'\\''" } + "'"
end

def read_file(path)
  File.open(path, "rb") { |f| f.read }
end

def write_file(path, text)
  File.open(path, "wb") { |f| f.write(text) }
end

# Runs a shell command line with stdout and stderr in files named after base; returns [status, stdout, stderr].
# The status is read back from the shell, since mruby has no Process.
def run_shell(cmd, base)
  o = "#{base}.stdout"
  e = "#{base}.stderr"
  io = IO.popen("#{cmd} >#{sh_quote(o)} 2>#{sh_quote(e)}; echo $?")
  status = io.read.to_i
  io.close
  so = read_file(o)
  se = read_file(e)
  File.delete(o)
  File.delete(e)
  [status, so, se]
end

# Integers outside the int64 range (a float64 bit pattern with the sign bit set) become Floats in JSON.parse. Every
# JSON number of 19 or more digits without a fraction or exponent is quoted, so it parses as a string, and
# restore_big_ints turns the data item values back into Integers. Strings are skipped as they are scanned.
def digit?(c)
  c >= 48 && c <= 57
end

def quote_big_ints(text)
  out = []
  last = 0
  i = 0
  n = text.bytesize
  while i < n
    c = text.getbyte(i)
    if c == 34 # a string: up to its closing quote (a backslash takes the next byte)
      j = i + 1
      while j < n
        d = text.getbyte(j)
        break if d == 34
        j += (d == 92) ? 2 : 1
      end
      i = j + 1
    elsif digit?(c) || c == 45 # a number (with a leading minus)
      k = (c == 45) ? i + 1 : i
      start = k
      k += 1 while k < n && digit?(text.getbyte(k))
      nxt = k < n ? text.getbyte(k) : -1
      if k - start >= 19 && nxt != 46 && nxt != 101 && nxt != 69 # not a fraction ".", exponent "e" or "E"
        out << text.byteslice(last, i - last) << '"' << text.byteslice(i, k - i) << '"'
        last = k
      end
      i = k
    else
      i += 1
    end
  end
  out << text.byteslice(last, n - last)
  out.join
end

def restore_big_ints(frag)
  frag["data"].each do |d|
    d["items"].each do |it|
      it[1] = it[1].to_i if NUMERIC_KINDS.include?(it[0]) && it[1].is_a?(String)
    end
  end
  frag
end

def load_fragment(path)
  restore_big_ints(JSON.parse(quote_big_ints(read_file(path))))
rescue StandardError => e
  die("#{path}: #{e.message}")
end

def build_shim(dirname, cc, out)
  src = "#{out}.shim.c"
  write_file(src, SHIM_C)
  status, _so, se = run_shell("#{sh_quote(cc)} -shared -fPIC -O2 -o #{sh_quote(dirname + '/libnfcxx_va.so')} " \
                              "#{sh_quote(src)} -ldl", "#{out}.shim")
  File.delete(src)
  if status != 0
    $stderr.write(se)
    die("building the variadic call shim failed")
  end
end

def main(args)
  out = nil
  paths = []
  ilasm = nil
  cc = "cc"
  keep_il = false
  i = 0
  while i < args.size
    a = args[i]
    if a == "-o"
      out = args[i + 1]
      i += 2
      next
    end
    if a == "--ilasm"
      ilasm = args[i + 1]
      i += 2
      next
    end
    if a == "--cc"
      cc = args[i + 1]
      i += 2
      next
    end
    if a == "--keep-il"
      keep_il = true
    elsif !a.start_with?("-")
      paths << a
    end
    i += 1 # link options (-l, -L, -O, ...) have no meaning for the CIL program
  end
  die("no -o OUT") if out.nil?
  frags = paths.map { |path| load_fragment(path) }
  die("no input fragments") if frags.empty?

  functions = {}
  data = {}
  calls = {}
  addrs = {}
  ctors = []
  frags.each do |fr|
    fr["functions"].each do |fn|
      die("function #{fn['name']} is defined twice") if functions.key?(fn["name"])
      functions[fn["name"]] = fn
    end
    fr["data"].each do |d|
      die("data #{d['name']} is defined twice") if data.key?(d["name"])
      data[d["name"]] = d
    end
    fr["calls"].each do |name, sig|
      if calls.key?(name) && calls[name] != sig
        die("#{name} is called with two signatures: #{sig_str(calls[name])} and #{sig_str(sig)}")
      end
      calls[name] = sig unless calls.key?(name)
    end
    fr["addrs"].each { |a| addrs[a] = true }
    ctors.concat(fr["ctors"])
  end

  # The C++ exception runtime of the Path B CIL spike (docs/notes/pathb-cil.md): a throw stores the object's storage
  # pointer in cxx_ptr and raises CxxThrow; the catch in the emitted IL reads cxx_ptr. Synthesized as functions, so
  # the address and init handling of other functions apply to them.
  used = {}
  calls.each_key { |n| used[n] = true }
  addrs.each_key { |n| used[n] = true }
  CXX_RUNTIME.each do |name, ret, params, body|
    next unless used.key?(name) && !functions.key?(name)
    il = [".method static #{ret} '#{name}'(#{params.join(', ')}) cil managed {", "  .maxstack 4"]
    body.each { |b| il << "    #{b}" }
    il << "}"
    functions[name] = { "name" => name, "ret" => ret, "params" => params, "exported" => true, "il" => il }
  end

  # Undefined functions: P/Invoke. Intrinsics with no CIL form become empty methods.
  externs = {}
  calls.each { |n, s| externs[n] = s unless functions.key?(n) }
  noops = {}
  externs.each { |n, s| noops[n] = s if NOOP_INTRINSICS.include?(n) }
  noops.each_key { |n| externs.delete(n) }
  calls.each do |n, s|
    next unless functions.key?(n)
    die("#{n} is defined as returning #{functions[n]['ret']} but called as #{s['ret']}") if functions[n]["ret"] != s["ret"]
  end
  calls.each do |n, s|
    next unless functions.key?(n)
    if functions[n]["params"] != s["params"] && !s["variadic"]
      die("#{n} is defined with #{py_list(functions[n]['params'])} but called with #{py_list(s['params'])}")
    end
  end

  # The program name for argv[0], as a data symbol.
  prog = basename(out)
  data["__nfcxx_argv0"] = { "name" => "__nfcxx_argv0", "exported" => false, "align" => 1,
                            "size" => char_len(prog) + 1,
                            "items" => prog.bytes.map { |c| ["int8", c] } + [["int8", 0]] }

  # Data addresses: every data symbol, every symbol used as a value, and every symbol a data item points at.
  names = {}
  data.each_key { |n| names[n] = true }
  addrs.each_key { |n| names[n] = true }
  data.each_value do |d|
    d["items"].each { |it| names[it[1]] = true if it[0] == "addr" }
  end
  sorted_names = names.keys.sort
  dlsym_names = sorted_names.select { |n| !data.key?(n) && !functions.key?(n) }
  sorted_data = data.keys.sort

  die("no main function") unless functions.key?("main")
  main_fn = functions["main"]

  lines = []
  lines << ".assembly extern System.Runtime { .ver 8:0:0:0 }"
  lines << ".assembly nfcxx_program { }"
  lines << ".module '#{qname(basename(out))}.dll'"
  # declared before its uses (ilasm needs the class first)
  lines << ".class public auto ansi CxxThrow extends [System.Runtime]System.Exception {"
  lines << "  .method public specialname rtspecialname instance void .ctor() cil managed {"
  lines << "    ldarg.0"
  lines << "    call instance void [System.Runtime]System.Exception::.ctor()"
  lines << "    ret"
  lines << "  }"
  lines << "}"
  lines << ".class public abstract sealed auto ansi beforefieldinit Prog extends [System.Runtime]System.Object {"
  sorted_names.each { |n| lines << "  .field public static int64 'addr_#{qname(n)}'" }
  lines << "  .field public static int64 'cxx_ptr'"

  # P/Invoke stubs for the functions this program calls and no unit defines (a variadic call goes through the shim).
  variadic = calls.values.any? { |s| s["variadic"] } || frags.any? { |fr| fr["variadic"] }
  externs.keys.sort.each do |n|
    s = externs[n]
    next if s["variadic"]
    lib = LIBM.include?(n) ? "libm.so.6" : "libc.so.6"
    lines << "  .method public static pinvokeimpl(\"#{lib}\" as \"#{n}\") #{s['ret']} '#{qname(n)}'" \
             "(#{s['params'].join(', ')}) cil managed preservesig { }"
  end
  noops.keys.sort.each do |n|
    s = noops[n]
    body = if s["ret"] == "void" then ["ret"]
           elsif s["ret"] == "int32" then ["ldc.i4.0", "ret"]
           else ["ldc.i8.0", "ret"]
           end
    lines << "  .method static #{s['ret']} '#{qname(n)}'(#{s['params'].join(', ')}) cil managed { .maxstack 2 " \
             "#{body.join(' ')} }"
  end
  if variadic
    floats = (["float64"] * 8).join(", ")
    ints = (["int64"] * 8).join(", ")
    lines << "  .method public static pinvokeimpl(\"libnfcxx_va\" as \"nfcxx_vcall\") int64 'nfcxx_vcall'(string, " \
             "int64, int64, int64, int64, int64, int64, #{floats}, #{ints}) cil managed preservesig { }"
  end
  # The libc functions the runtime itself uses.
  [["calloc", "int64", ["int64", "int64"]], ["dlsym", "int64", ["int64", "string"]], ["strdup", "int64", ["string"]]].each do |n, ret, ps|
    lines << "  .method public static pinvokeimpl(\"libc.so.6\" as \"#{n}\") #{ret} '#{n}'(#{ps.join(', ')}) " \
             "cil managed preservesig { }"
  end

  # Functions.
  functions.each_value { |fn| lines << fn["il"].join("\n") }

  # Init: allocate, fill addresses, write the data, run the constructors.
  init = [".method static void Init() cil managed {", "  .maxstack 1024", "  .locals init (int64 V0)"]
  sorted_data.each do |n|
    init << "    ldc.i8 #{[data[n]['size'], 1].max}" << "    ldc.i8 1" << "    call int64 Prog::'calloc'(int64, int64)" <<
      "    stsfld int64 Prog::'addr_#{qname(n)}'"
  end
  dlsym_names.each do |n|
    init << "    ldc.i8 0" << "    ldstr \"#{n}\"" << "    call int64 Prog::'dlsym'(int64, string)" <<
      "    stsfld int64 Prog::'addr_#{qname(n)}'"
  end
  sorted_names.each do |n|
    next unless functions.key?(n) && !data.key?(n)
    fn = functions[n]
    init << "    ldftn #{fn['ret']} Prog::'#{qname(n)}'(#{fn['params'].join(', ')})" << "    conv.u8" <<
      "    stsfld int64 Prog::'addr_#{qname(n)}'"
  end
  sorted_data.each do |n|
    off = 0
    data[n]["items"].each do |it|
      kind = it[0]
      if kind == "zero"
        off += it[1]
        next
      end
      base = ["    ldsfld int64 Prog::'addr_#{qname(n)}'", "    ldc.i8 #{off}", "    add", "    conv.u"]
      if kind == "addr"
        init.concat(base)
        init << "    ldsfld int64 Prog::'addr_#{qname(it[1])}'" << "    ldc.i8 #{it[2]}" << "    add" << "    stind.i8"
        off += 8
        next
      end
      width = { "int8" => 1, "int16" => 2, "int32" => 4, "int64" => 8, "float32" => 4, "float64" => 8 }[kind]
      if kind == "float32" || kind == "float64"
        # the bit pattern: an unsigned integer that fits the width (to_bytes refuses anything else)
        die("#{kind} item of #{n} is not a bit pattern: #{it[1]}") unless it[1].is_a?(Integer) && it[1] >= 0 && it[1] < (1 << (8 * width))
        hex = le_bytes(it[1], width).map { |b| format("%02x", b) }.join(" ")
        init.concat(base)
        if kind == "float32"
          init << "    ldc.r4 (#{hex})" << "    stind.r4"
        else
          init << "    ldc.r8 (#{hex})" << "    stind.r8"
        end
      elsif kind == "int64"
        init.concat(base)
        init << "    ldc.i8 #{it[1]}" << "    stind.i8"
      else
        suffix = { "int8" => "i1", "int16" => "i2", "int32" => "i4" }[kind]
        init.concat(base)
        init << "    ldc.i4 #{it[1]}" << "    stind.#{suffix}"
      end
      off += width
    end
  end
  ctors.each do |c|
    init << "    call void Prog::'#{qname(c)}'()" if functions.key?(c)
  end
  init << "    ret"
  init << "}"
  lines << init.join("\n")

  # The entry point: Init, argv (the program name, then the arguments after the .dll), main.
  ps = main_fn["params"]
  entry = [".method static int32 EntryPoint() cil managed {", "  .entrypoint", "  .maxstack 1024",
           "  .locals init (int64 V0, string[] V1, int32 V2, int32 V3)", "    call void Prog::Init()"]
  if !ps.empty?
    die("main takes #{py_list(ps)}; only main(void) and main(int, char **) are supported") if ps != ["int32", "int64"]
    # args = Environment.GetCommandLineArgs(): the .dll path, then the arguments; argc = its length
    entry += ["    call string[] [System.Runtime]System.Environment::GetCommandLineArgs()", "    stloc.1",
              "    ldloc.1", "    ldlen", "    conv.i4", "    stloc.2",
              "    ldloc.2", "    conv.i8", "    ldc.i8 1", "    add", "    ldc.i8 8", "    mul", "    ldc.i8 1",
              "    call int64 Prog::'calloc'(int64, int64)", "    stloc.0",
              "    ldloc.0", "    conv.u", "    ldsfld int64 Prog::'addr___nfcxx_argv0'", "    stind.i8",
              "    ldc.i4.1", "    stloc.3",
              "IL_argv_loop:", "    ldloc.3", "    ldloc.2", "    bge IL_argv_done",
              "    ldloc.0", "    ldloc.3", "    conv.i8", "    ldc.i8 8", "    mul", "    add", "    conv.u",
              "    ldloc.1", "    ldloc.3", "    ldelem.ref", "    call int64 Prog::'strdup'(string)", "    stind.i8",
              "    ldloc.3", "    ldc.i4.1", "    add", "    stloc.3", "    br IL_argv_loop",
              "IL_argv_done:",
              "    ldloc.2", "    ldloc.0", "    call int32 Prog::'main'(int32, int64)"]
  elsif main_fn["ret"] == "int32"
    entry << "    call int32 Prog::'main'()"
  else
    entry += ["    call void Prog::'main'()", "    ldc.i4.0"]
  end
  entry += ["    pop", "    ldc.i4.0"] if !ps.empty? && main_fn["ret"] != "int32"
  entry += ["    ret", "}"]
  lines << entry.join("\n")
  lines << "}"

  ilasm = "#{File.dirname($0)}/../build/cil/ilasm" if ilasm.nil? || ilasm.empty?
  build_shim(File.dirname(out), cc, out) if variadic

  text = lines.join("\n") + "\n"
  dll = out + ".dll"
  write_file("#{out}.il", text) if keep_il # debugging: keep the CIL text next to the output
  die("ilasm not found at #{ilasm} (run scripts/setup-cil.sh, or pass --ilasm)") unless File.exist?(ilasm)
  il_path = "#{out}.tmp.il"
  write_file(il_path, text)
  status, so, se = run_shell("#{sh_quote(ilasm)} -exe #{sh_quote("-output=#{dll}")} #{sh_quote(il_path)}", "#{out}.ilasm")
  File.delete(il_path)
  if status != 0
    $stderr.write(so + se)
    write_file("#{out}.failed.il", text)
    die("ilasm failed (the IL is in #{out}.failed.il)")
  end
  write_file("#{out}.runtimeconfig.json",
             '{"runtimeOptions": {"tfm": "net8.0", "rollForward": "LatestMajor", ' \
             '"framework": {"name": "Microsoft.NETCore.App", "version": "' + RUNTIME + '"}}}')
  write_file(out, "#!/bin/sh\n" + 'exec dotnet "$(dirname "$0")/' + basename(dll) + "\" \"$@\"\n")
  File.chmod(493, out) # 0755
end

main(ARGV)
