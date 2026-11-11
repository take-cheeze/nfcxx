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

class Die < StandardError; end

def die(msg)
  raise Die, msg
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

# A JSON parser for the fragments (the compiled world has no JSON). Objects become Hashes, arrays Arrays, numbers
# Integers or Floats, strings UTF-8 Strings. Numbers of 19 or more digits are read as strings by quote_big_ints first.
class JsonParser
  def initialize(text)
    @s = text
    @i = 0
    @n = text.bytesize
  end

  def fail_at(what)
    raise Die, "#{what} at byte #{@i}"
  end

  def ws
    while @i < @n
      c = @s.getbyte(@i)
      break unless c == 32 || c == 9 || c == 10 || c == 13
      @i += 1
    end
  end

  def parse
    ws
    v = value
    ws
    fail_at("unexpected trailing data") if @i < @n
    v
  end

  def value
    fail_at("unexpected end of input") if @i >= @n
    c = @s.getbyte(@i)
    if c == 123
      object
    elsif c == 91
      array
    elsif c == 34
      string
    elsif c == 45 || digit?(c)
      number
    elsif @s.byteslice(@i, 4) == "true"
      @i += 4
      true
    elsif @s.byteslice(@i, 5) == "false"
      @i += 5
      false
    elsif @s.byteslice(@i, 4) == "null"
      @i += 4
      nil
    else
      fail_at("unexpected token")
    end
  end

  def object
    h = {}
    @i += 1
    ws
    if @i < @n && @s.getbyte(@i) == 125
      @i += 1
      return h
    end
    while true
      ws
      fail_at("expected a string key") unless @i < @n && @s.getbyte(@i) == 34
      k = string
      ws
      fail_at("expected ':'") unless @i < @n && @s.getbyte(@i) == 58
      @i += 1
      ws
      h[k] = value
      ws
      fail_at("unterminated object") if @i >= @n
      c = @s.getbyte(@i)
      @i += 1
      break if c == 125
      fail_at("expected ',' or '}'") unless c == 44
    end
    h
  end

  def array
    a = []
    @i += 1
    ws
    if @i < @n && @s.getbyte(@i) == 93
      @i += 1
      return a
    end
    while true
      ws
      a << value
      ws
      fail_at("unterminated array") if @i >= @n
      c = @s.getbyte(@i)
      @i += 1
      break if c == 93
      fail_at("expected ',' or ']'") unless c == 44
    end
    a
  end

  def hex4
    fail_at("bad \\u escape") if @i + 4 > @n
    v = 0
    4.times do
      c = @s.getbyte(@i)
      d = if c >= 48 && c <= 57 then c - 48
          elsif c >= 97 && c <= 102 then c - 87
          elsif c >= 65 && c <= 70 then c - 55
          else fail_at("bad \\u escape")
          end
      v = v * 16 + d
      @i += 1
    end
    v
  end

  def utf8(cp)
    if cp < 0x80
      cp.chr
    elsif cp < 0x800
      (0xC0 | (cp >> 6)).chr + (0x80 | (cp & 0x3F)).chr
    elsif cp < 0x10000
      (0xE0 | (cp >> 12)).chr + (0x80 | ((cp >> 6) & 0x3F)).chr + (0x80 | (cp & 0x3F)).chr
    else
      (0xF0 | (cp >> 18)).chr + (0x80 | ((cp >> 12) & 0x3F)).chr + (0x80 | ((cp >> 6) & 0x3F)).chr +
        (0x80 | (cp & 0x3F)).chr
    end
  end

  def string
    @i += 1
    out = String.new
    while true
      fail_at("unterminated string") if @i >= @n
      c = @s.getbyte(@i)
      @i += 1
      break if c == 34
      if c == 92
        fail_at("unterminated string") if @i >= @n
        e = @s.getbyte(@i)
        @i += 1
        if e == 110 then out << "\n"
        elsif e == 116 then out << "\t"
        elsif e == 114 then out << "\r"
        elsif e == 98 then out << "\b"
        elsif e == 102 then out << "\f"
        elsif e == 34 || e == 92 || e == 47 then out << e.chr
        elsif e == 117
          cp = hex4
          if cp >= 0xD800 && cp < 0xDC00 && @s.byteslice(@i, 2) == "\\u"
            @i += 2
            lo = hex4
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
          end
          out << utf8(cp)
        else
          fail_at("bad escape")
        end
      else
        out << c.chr
      end
    end
    out.respond_to?(:force_encoding) ? out.force_encoding("UTF-8") : out
  end

  def number
    st = @i
    @i += 1 if @s.getbyte(@i) == 45
    @i += 1 while @i < @n && digit?(@s.getbyte(@i))
    fl = false
    if @i < @n && @s.getbyte(@i) == 46
      fl = true
      @i += 1
      @i += 1 while @i < @n && digit?(@s.getbyte(@i))
    end
    if @i < @n && (@s.getbyte(@i) == 101 || @s.getbyte(@i) == 69)
      fl = true
      @i += 1
      @i += 1 if @i < @n && (@s.getbyte(@i) == 43 || @s.getbyte(@i) == 45)
      @i += 1 while @i < @n && digit?(@s.getbyte(@i))
    end
    t = @s.byteslice(st, @i - st)
    fl ? t.to_f : t.to_i
  end
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
  restore_big_ints(JsonParser.new(quote_big_ints(read_file(path))).parse)
rescue Die, SystemCallError => e
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

def link(args)
  out = nil
  paths = []
  ilasm = nil
  cc = "cc"
  keep_il = false
  il_only = false
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
    elsif a == "--il-only"
      il_only = true
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

  text = lines.join("\n") + "\n"
  if il_only # print the CIL text and stop: no ilasm, no shim, no launcher
    $stdout.write(text)
    return
  end
  ilasm = "#{File.dirname($0)}/../build/cil/ilasm" if ilasm.nil? || ilasm.empty?
  build_shim(File.dirname(out), cc, out) if variadic

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

def main(args)
  link(args)
  0
rescue Die => e
  $stderr.puts("cil-link: #{e.message}")
  1
end

rc = main(ARGV)
exit(rc) if rc != 0
