# Path B: emit SPIR-V (a Vulkan compute module) from the nfcxx mid-level IR text (docs/notes/pathb-stage2.md), for the SYCL
# path (docs/notes/sycl-webgpu.md). The same kernels as scripts/pathb-wgsl-emit.rb, without WebGPU's limits: pointers are
# 64-bit physical addresses (PhysicalStorageBuffer64), so the IR's LP64 layout is kept as it is; 64-bit integers and double
# are real types; barriers and atomics are the SPIR-V ones.
#
# Usage: scripts/mrb scripts/pathb-spirv-emit.rb [--manifest=FILE] [FILE.ir | -] > out.spv
#
# Exit status: 0 the module was written (binary, to stdout); 3 refused (reason on stderr); 1 malformed IR.
#
# Module. One SPIR-V module holds every kernel: an entry point `k<N>` per kernel (GLCompute, local size from the specialization
# constants SX/SY/SZ), and the functions they reach. Kernels take no parameters; the entry reads the closure and the launch
# data from push constants (layout in PUSH_MEMBERS, the host writes the same struct in rt_vulkan.hpp):
#   closure (the kernel's captured state), statics (the constant tables and globals), stack (the per-invocation stacks),
#   local (the work-group memory), flag (a u32 that a failed check sets), gsize[3] (the global range), ngroups[3],
#   stack_bytes (per invocation), local_stride (per work-group), local_user (bytes of local_accessor storage).
# Built-ins: GlobalInvocationId, LocalInvocationId, WorkgroupId.
#
# Memory. An IR pointer is a u64 address; each load and store is an OpLoad/OpStore through an OpConvertUToPtr pointer of
# PhysicalStorageBuffer class, with the alignment the IR gives. Bytes and halfwords are loaded and stored as aligned 32-bit
# words (a store is an atomic and/or on the word). Scalar slots whose address is never taken are Function variables; the
# other slots live in the invocation's stack (a frame per call, sp in a Private variable). Registers are Function variables.
#
# Checks: division, shifts, bounds, nonnull, trap and float-to-integer conversions set the flag (an atomic max of the code,
# codes as in pathb-wgsl-emit.rb) and return from the current function with zero results. A call returns in turn while the
# `dead` flag is set, so no invocation goes on to touch memory after a failed check. A loop's step runs at the top of each
# iteration but the first, before the condition (so the continue construct has no checks in it: SPIR-V's structure rules
# for it are strict); a function's frame is released on every return.
#
# Structure. Loops are OpLoopMerge headers; an if is a selection; switch is OpSwitch with fallthrough only where the arm ends
# in a jump; break, continue and the labels the front end puts after loops and switches are branches to those blocks.
#
# Not handled (refused with the reason): goto other than loop and switch exits, recursion, switch arms that fall through,
# a kernel with parameters, function addresses, zero-initialized globals (as in the WGSL emitter), copysign.

class Refused < StandardError; end   # a node this emitter does not handle (exit status 3)
class BadIR < StandardError; end     # malformed IR text (exit status 1)


# ------------------------------------------------------------------ reading the IR text (as pathb-qbe-emit.rb)

class IRStr
  attr_reader :bytes

  def initialize(bytes)
    @bytes = bytes
  end

  def to_s
    s = "".b
    @bytes.each { |c| s << (c & 255).chr }
    s
  end
end

# A sigil and a quoted name: $"x" (slot), @"x" (static object), &"f" (function).
class IRSym
  attr_reader :sig, :name

  def initialize(sig, name)
    @sig = sig
    @name = name
  end
end

def space_byte?(c)
  (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0x85 || c == 0xa0
end

def octal?(c)
  c >= 48 && c <= 55
end

def read_string(text, i)
  out = []
  i += 1
  n = text.bytesize
  while true
    raise BadIR, "unterminated string in IR" if i >= n
    c = text.getbyte(i)
    return [out, i + 1] if c == 34
    if c == 92
      i += 1
      raise BadIR, "bad escape at end of IR" if i >= n
      e = text.getbyte(i)
      if e == 110
        out << 10
        i += 1
      elsif e == 34 || e == 92
        out << e
        i += 1
      elsif e >= 48 && e <= 55 && i + 2 < n && octal?(text.getbyte(i + 1)) && octal?(text.getbyte(i + 2))
        out << ((e - 48) * 64 + (text.getbyte(i + 1) - 48) * 8 + (text.getbyte(i + 2) - 48))
        i += 3
      else
        raise BadIR, "unknown escape \\#{e.chr} in IR string"
      end
    else
      out << c
      i += 1
    end
  end
end

def tokenize(text)
  toks = []
  i = 0
  n = text.bytesize
  while i < n
    c = text.getbyte(i)
    if space_byte?(c)
      i += 1
    elsif c == 40 || c == 41
      toks << c.chr
      i += 1
    elsif c == 34
      s, i = read_string(text, i)
      toks << IRStr.new(s)
    elsif (c == 36 || c == 64 || c == 38) && i + 1 < n && text.getbyte(i + 1) == 34
      s, i = read_string(text, i + 1)
      toks << IRSym.new(c.chr, IRStr.new(s).to_s)
    else
      j = i
      while j < n
        d = text.getbyte(j)
        break if space_byte?(d) || d == 40 || d == 41 || d == 34
        j += 1
      end
      toks << text.byteslice(i, j - i)
      i = j
    end
  end
  toks
end

# The list of top-level forms. A form is an Array, or an atom (String, IRStr, IRSym).
def parse_forms(toks)
  stack = [[]]
  toks.each do |t|
    if t.is_a?(String) && t == "("
      stack << []
    elsif t.is_a?(String) && t == ")"
      raise BadIR, "unbalanced ')' in IR" if stack.length == 1
      done = stack.pop
      stack[-1] << done
    else
      stack[-1] << t
    end
  end
  raise BadIR, "unbalanced '(' in IR" if stack.length != 1
  stack[0]
end

# EDG's exception-handling state (lib_src/eh.h). A noexcept function (libstdc++'s std::array::operator[], for one) pushes
# a kind-6 entry on __curr_eh_stack_entry and pops it on every exit; nothing on the device unwinds, so the cells are
# ordinary static storage here, not an extern to refuse.
EH_RUNTIME_STATE = %w[__curr_eh_stack_entry __eh_curr_region __catch_clause_number __caught_object_address].freeze
# libstdc++'s __glibcxx_assert_fail (the failing branch of std::array::operator[] and other _GLIBCXX_ASSERTIONS checks)
GLIBCXX_ASSERT_FAIL = "_ZSt21__glibcxx_assert_failPKciS0_S0_".freeze

def head_of(x)
  x.is_a?(Array) && !x.empty? && x[0].is_a?(String) ? x[0] : nil
end

def form_text(x)
  if x.is_a?(Array)
    "(" + x.map { |y| form_text(y) }.join(" ") + ")"
  elsif x.is_a?(IRSym)
    x.sig + "\"" + x.name + "\""
  elsif x.is_a?(IRStr)
    "\"" + x.to_s + "\""
  else
    x.to_s
  end
end

# The signed 64-bit value with the bit pattern of n (an unsigned constant above 2**63 is negative in an i64).
def signed64(n)
  n &= 0xffffffffffffffff
  n >= 0x8000000000000000 ? n - 0x10000000000000000 : n
end

# A decimal or hexadecimal (0x...) integer, with an optional minus sign.
def as_int(x)
  raise BadIR, "expected an integer, got #{form_text(x)}" unless x.is_a?(String) && x.length > 0
  neg = false
  s = x
  if s[0] == "-"
    neg = true
    s = s[1..-1]
  end
  hex = s.length > 2 && s[0] == "0" && (s[1] == "x" || s[1] == "X")
  s = s[2..-1] if hex
  raise BadIR, "expected an integer, got #{x}" if s.length == 0
  base = hex ? 16 : 10
  v = 0
  s.each_char do |c|
    d = if c >= "0" && c <= "9" then c.ord - 48
        elsif hex && c >= "a" && c <= "f" then c.ord - 87
        elsif hex && c >= "A" && c <= "F" then c.ord - 55
        else raise BadIR, "expected an integer, got #{x}"
        end
    v = v * base + d
  end
  neg ? -v : v
end


# ------------------------------------------------------------------ types
# ["int", size, signed, bool], ["float", size], ["ptr"], ["void"]. Aggregates exist only in memory (slots, copy).

VOID = ["void"]
SCALARS = {
  "bool" => ["int", 1, false, true],
  "char" => ["int", 1, true, false],
  "signed_char" => ["int", 1, true, false],
  "unsigned_char" => ["int", 1, false, false],
  "short" => ["int", 2, true, false],
  "unsigned_short" => ["int", 2, false, false],
  "int" => ["int", 4, true, false],
  "unsigned_int" => ["int", 4, false, false],
  "long" => ["int", 8, true, false],
  "unsigned_long" => ["int", 8, false, false],
  "long_long" => ["int", 8, true, false],
  "unsigned_long_long" => ["int", 8, false, false],
  "float" => ["float", 4],
  "double" => ["float", 8],
}

def parse_type(x)
  if x.is_a?(String)
    return VOID if x == "void"
    return SCALARS[x] if SCALARS.key?(x)
    raise Refused, "type #{x}"
  end
  raise BadIR, "bad type form #{form_text(x)}" if !x.is_a?(Array) || x.empty?
  return ["ptr"] if x[0] == "ptr" || x[0] == "byval" || x[0] == "sret"
  return parse_type(x[1]) if x[0] == "const" || x[0] == "volatile"
  raise Refused, "type form (#{x[0]} ...)"
end

# true when the type form is a scalar or pointer (a candidate for a WGSL local variable)
def scalar_form?(x)
  parse_type(x)
  true
rescue Refused
  false
end

def int_ty?(t)
  t[0] == "int" && !t[3]
end

def bool_ty?(t)
  t[0] == "int" && t[3]
end


# ------------------------------------------------------------------ functions

def collect_calls(x, acc)
  return acc unless x.is_a?(Array)
  if head_of(x) == "call" && x.length > 2 && x[2].is_a?(IRSym) && x[2].sig == "&"
    acc << x[2].name
  end
  x.each { |y| collect_calls(y, acc) }
  acc
end

# Names of the slots a form takes the address of in a way other than the address of a load or a store.
# A function-pointer local whose every store is the address of one function (a constexpr pointer, e.g. a template selector's
# result: the front end stores it into a slot, then calls it through a load) is folded: the stores are dropped and each call
# through a load of the slot calls that function directly (the same direct call the front end emits for a known callee).
# Any other use of the slot (a load used as a value, a store of another address, the slot's address) leaves it alone.
# The front end default-initialises an array of a class with a non-trivial constructor by one runtime helper call,
# __cxa_vec_ctor(array, count, size, constructor address, null). The device pass has no runtime helper and no constructor
# address, so the call is unrolled here into one direct call of the constructor per element (the element address is the
# array plus i * size). The let that holds the constructor's address is dropped when that address was used only by these
# calls. Any other use of the address stays and is refused as before.
def cxa_count(x, name)
  return (x == name ? 1 : 0) if x.is_a?(String)
  return 0 unless x.is_a?(Array)
  x.inject(0) { |a, y| a + cxa_count(y, name) }
end

def cxa_ctor_refs(x, name)
  return 0 unless x.is_a?(Array)
  n = 0
  if head_of(x) == "call" && x[2].is_a?(IRSym) && x[2].name == "__cxa_vec_ctor" && x[6] == name
    n += 1
  end
  x.each { |y| n += cxa_ctor_refs(y, name) }
  n
end

def cxa_resolve(a, regs)
  return a.name if a.is_a?(IRSym) && a.sig == "&"
  return regs[a] if a.is_a?(String) && regs.key?(a)
  nil
end

def expand_cxa_vec_ctor(body)
  counter = [0]
  expand = lambda do |x, regs|
    out = []
    x.each do |c|
      if head_of(c) == "let" && c.length == 4 && c[3].is_a?(Array) && head_of(c[3]) == "bitcast" &&
         c[3][2].is_a?(IRSym) && c[3][2].sig == "&"
        regs[c[1]] = c[3][2].name
        # dropped when its address is used only as a constructor argument
        next if cxa_count(body, c[1]) == 1 + cxa_ctor_refs(body, c[1])
        out << c
        next
      end
      if head_of(c) == "eval" && c[1].is_a?(Array) && head_of(c[1]) == "call" && c[1][2].is_a?(IRSym) &&
         c[1][2].sig == "&" && c[1][2].name == "__cxa_vec_ctor"
        call = c[1]
        ctor = cxa_resolve(call[6], regs)
        raise Refused, "__cxa_vec_ctor with an unknown constructor" if ctor.nil?
        raise Refused, "__cxa_vec_ctor with a destructor" unless head_of(call[7]) == "null"
        raise Refused, "__cxa_vec_ctor with a non-constant count" unless head_of(call[4]) == "const" && call[3].is_a?(String)
        n = as_int(call[4][2])
        size = call[5][2]
        n.times do |i|
          counter[0] += 1
          r = "%cxa#{counter[0]}"
          out << ["let", r, ["ptr", "void"], ["index", call[3], ["const", "unsigned_long", i.to_s], size]]
          out << ["eval", ["call", "void", IRSym.new("&", ctor), r]]
        end
        next
      end
      expand.call(c, regs) if c.is_a?(Array)
      out << c
    end
    x.replace(out)
  end
  expand.call(body, {})
end

# A work-group static (syclex::work_group_static<T>, lib/sycl ext/oneapi/work_group_static.hpp) is one buffer per work-group,
# not one per work-item. Its object (a kernel-body slot whose type names work_group_static) is placed in the group's static
# local region, after the 1024-byte scratch tail of the group's local memory: the host reserves wgs_total bytes more per
# work-group (manifest line L; rt_opencl.hpp, rt_level_zero.hpp). Offsets are unique across the module; the map is keyed by
# [function name, slot name] and wgs_layout returns [map, total bytes (16-aligned)].
def mentions_wgs?(t)
  return t.to_s.include?("work_group_static") if t.is_a?(String) || t.is_a?(IRStr)   # quoted names are IRStr
  return false unless t.is_a?(Array)
  t.any? { |y| mentions_wgs?(y) }
end

def wgs_layout(defs)
  map = {}
  total = 0
  defs.each do |fname, form|
    next unless form.is_a?(Array)
    form.each do |f|
      # the object itself: a slot of the struct type (not a pointer to it, as the constructors' parameters are)
      next unless head_of(f) == "slot" && f.length == 5 && head_of(f[2]) == "struct" && mentions_wgs?(f[2])
      size = as_int(f[3])
      align = [as_int(f[4]), 16].max
      total = (total + align - 1) / align * align
      map[[fname, f[1].to_s]] = total
      total += size
    end
  end
  [map, (total + 15) / 16 * 16]
end

def fnptr_slot?(t)
  t = t[1] if head_of(t) == "const"
  head_of(t) == "ptr" && t.length > 1 && head_of(t[1]) == "fn"
end

def fnptr_scan(x, st)
  if x.is_a?(IRSym)
    st[:bad][x.name] = true if x.sig == "$" && st[:names][x.name]
    return
  end
  return unless x.is_a?(Array)
  h = head_of(x)
  if h == "store" && x[2].is_a?(IRSym) && x[2].sig == "$" && st[:names][x[2].name]
    n = x[2].name
    v = x[3]
    if v.is_a?(IRSym) && v.sig == "&" && (st[:target][n].nil? || st[:target][n] == v.name)
      st[:target][n] = v.name
      st[:drop][x.object_id] = n
    else
      st[:bad][n] = true
    end
    return
  end
  if h == "call" && x[2].is_a?(Array) && head_of(x[2]) == "load" && x[2][2].is_a?(IRSym) && x[2][2].sig == "$" &&
     st[:names][x[2][2].name]
    st[:calls][x[2].object_id] = x[2][2].name
    x.drop(3).each { |y| fnptr_scan(y, st) }
    return
  end
  if h == "load" && x[2].is_a?(IRSym) && x[2].sig == "$" && st[:names][x[2].name]
    st[:bad][x[2].name] = true
    return
  end
  x.each { |y| fnptr_scan(y, st) }
end

def fnptr_rewrite(x, st)
  return unless x.is_a?(Array)
  x.reject! { |c| c.is_a?(Array) && st[:drop].key?(c.object_id) }
  if head_of(x) == "call" && x[2].is_a?(Array) && st[:calls].key?(x[2].object_id)
    x[2] = IRSym.new("&", st[:target][st[:calls][x[2].object_id]])
  end
  x.each { |c| fnptr_rewrite(c, st) }
end

def fold_fnptr_slots(body, slots)
  st = { names: {}, target: {}, bad: {}, drop: {}, calls: {} }
  slots.each { |f| st[:names][f[1].to_s] = true if fnptr_slot?(f[2]) }
  return if st[:names].empty?
  body.each { |s| fnptr_scan(s, st) }
  ok = {}
  st[:names].each_key { |n| ok[n] = true if st[:target][n] && !st[:bad][n] }
  return if ok.empty?
  st[:drop].delete_if { |_, n| !ok[n] }
  st[:calls].delete_if { |_, n| !ok[n] }
  body.reject! { |s| s.is_a?(Array) && st[:drop].key?(s.object_id) }
  body.each { |s| fnptr_rewrite(s, st) }
end

def scan_slots(x, direct, escaped)
  if x.is_a?(IRSym)
    escaped[x.name] = true if x.sig == "$"
    return
  end
  return unless x.is_a?(Array)
  h = head_of(x)
  if (h == "load" || h == "store" || h == "load.v" || h == "store.v") && x[2].is_a?(IRSym) && x[2].sig == "$"
    (direct[x[2].name] ||= []) << parse_type_safe(x[1])
    scan_slots(x[3], direct, escaped) if h == "store" || h == "store.v"
    return
  end
  x.each { |y| scan_slots(y, direct, escaped) }
end

def parse_type_safe(x)
  parse_type(x)
rescue Refused
  nil
end

class Mod
  attr_accessor :defs, :fns, :need, :globals, :datas, :statics, :static_order, :static_size, :empty_types
  def initialize
    @defs = {}     # IR name => function form
    @fns = {}      # IR name => Fn (the reachable ones)
    @need = {}     # prelude helpers used
    @globals = {}  # IR name => global form
    @datas = {}    # IR name => data form (string literals)
    @empty_types = {}  # IR struct name => true for the empty ABI types (abi-type ... (empty))
    @statics = {}  # name => byte offset in the static region (the objects a kernel uses)
    @static_order = []
    @static_size = 0
  end

  # The WGSL expression for the address of a static object. The region is allocated by the server at load time
  # (STATIC_BASE is a pipeline constant) and filled from the manifest.
  def static_offset(name)
    unless @statics.key?(name)
      f = @globals[name]
      d = @datas[name]
      raise Refused, "static object @\"#{name}\" has no definition in the device unit" if f.nil? && d.nil?
      size, align = if f
                      raise Refused, "static object @\"#{name}\" is extern" if f.drop(5).any? { |x| head_of(x) == "extern" } && !EH_RUNTIME_STATE.include?(name)
                      [as_int(f[3]), as_int(f[4])]
                    else
                      [static_bytes(d).length, 1]
                    end
      align = 4 if align < 4
      off = (@static_size + align - 1) / align * align
      @statics[name] = off
      @static_order << name
      @static_size = off + size
      # objects this one points to are laid out too
      if f
        init = f.drop(5).find { |x| head_of(x) == "init" }
        init.drop(1).each { |it| static_offset(it[3].name) if head_of(it) == "addr" && it[3].is_a?(IRSym) && it[3].sig == "@" } if init
      end
    end
    @statics[name]   # the byte offset in the static region (the module adds the region's address)
  end

  def static_bytes(d)
    str = d[3]
    raise Refused, "data #{d[1]}: form #{form_text(d[3])}" unless head_of(str) == "string"
    str[1].to_s.bytes
  end

  # The initial bytes of the static region and its relocations ([offset, target offset]).
  def static_image
    bytes = Array.new(@static_size, 0)
    relocs = []
    @static_order.each do |name|
      base = @statics[name]
      if @datas.key?(name)
        static_bytes(@datas[name]).each_with_index { |b, i| bytes[base + i] = b }
        next
      end
      f = @globals[name]
      init = f.drop(5).find { |x| head_of(x) == "init" }
      next if init.nil? && EH_RUNTIME_STATE.include?(name)   # the EH state starts zeroed, as an extern cell would be
      raise Refused, "static object #{name} has no initializer" if init.nil?
      nonzero = false
      init.drop(1).each do |it|
        h = head_of(it)
        off = base + as_int(it[1])
        case h
        when "scalar"
          ty = parse_type(it[2])
          v = it[3]
          if head_of(v) == "null"
            n = 0
          elsif ty[0] == "float"
            raise Refused, "static #{name}: double" unless ty[1] == 4
            n = float_bits(v[2].to_s)
          else
            n = as_int(v[2])
          end
          nonzero = true if n != 0
          size = ty[0] == "ptr" ? 8 : ty[1]
          size.times { |i| bytes[off + i] = (n >> (8 * i)) & 255 }
        when "bytes"
          src = @datas[it[3].name]
          raise Refused, "static #{name}: bytes of #{it[3].name}" if src.nil?
          sb = static_bytes(src)
          as_int(it[2]).times { |i| bytes[off + i] = sb[i] || 0 }
          nonzero = true
        when "zero"
          nil
        when "addr"
          raise Refused, "static #{name}: address of a function" unless it[3].is_a?(IRSym) && it[3].sig == "@"
          relocs << [off, @statics[it[3].name] + as_int(it[4])]
          nonzero = true
        else
          raise Refused, "static #{name}: initializer item #{h}"
        end
      end
      # An object of an empty ABI type (abi-type ... (empty)) has no members: its zero bytes are its whole value, and no
      # initializer can change them, so it is lowered as the zero bytes it has. This covers a lambda closure with no captures
      # and a functor such as sycl::plus<T>, which a call passes by value. Any other zero-initialized object is refused.
      cname = head_of(f[2]) == "struct" ? f[2][1].to_s : ""
      empty_obj = @empty_types[cname] == true
      raise Refused, "static object #{name} is zero-initialized (a dynamic initializer would look the same in the IR, so it is not trusted)" unless nonzero || empty_obj
    end
    [bytes, relocs]
  end
end

# the bit pattern of a float32 given as the IR's decimal text (or an infinity)
def float_bits(text)
  return 0x7f800000 if text == "+Infinity" || text == "Infinity"
  return 0xff800000 if text == "-Infinity"
  [text.to_f].pack("f").unpack("V")[0]
end


# The kernel key: the closure type that the entry casts __nfcxx_sycl_closure() to.
def kernel_key(form)
  reg = nil
  found = nil
  walk = lambda do |x|
    next unless x.is_a?(Array)
    if head_of(x) == "let" && x.length == 4 && head_of(x[3]) == "call" && x[3][2].is_a?(IRSym) && x[3][2].name == "__nfcxx_sycl_closure"
      reg = x[1]
    elsif found.nil? && reg && head_of(x) == "let" && x.length == 4 && head_of(x[3]) == "bitcast" && x[3][2] == reg
      t = x[3][1]
      t = t[1] while t.is_a?(Array) && (t[0] == "ptr" || t[0] == "const" || t[0] == "volatile")
      found = t[1].to_s if head_of(t) == "struct"
    end
    x.each { |y| walk.call(y) }
  end
  walk.call(form)
  return nil if found.nil?
  [found.start_with?("_Z") ? found[2..-1] : "#{found.length}#{found}", found]
end

def strip_comments(src)
  keep = []
  src.split("\n").each do |line|
    keep << line unless line.lstrip.start_with?(";")
  end
  keep.join("\n")
end

def read_input(path)
  File.open(path, "rb") { |f| f.read }
end


# ------------------------------------------------------------------ the SPIR-V module builder

# Opcodes (SPIR-V 1.5), storage classes, scopes and semantics used below.
OP_NAME_DECORATE = 71
OP_MEMBER_DECORATE = 72
SC_UNIFORM_CONSTANT = 0
SC_INPUT = 1
SC_WORKGROUP = 4
SC_PRIVATE = 6
SC_FUNCTION = 7
SC_PUSH_CONSTANT = 9
SC_CROSSWG = 5
SC_PSB = 5349
SCOPE_DEVICE = 1
SCOPE_WORKGROUP = 2
SCOPE_SUBGROUP = 3
SEM_RELAXED = 0
SEM_BARRIER = 0x8 | 0x40 | 0x100 | 0x200   # AcquireRelease | UniformMemory | WorkgroupMemory | CrossWorkgroupMemory
SEM_BARRIER_KERNEL = 0x8 | 0x100 | 0x200   # the same without UniformMemory (which needs the Shader capability)
SEM_SG_BARRIER_KERNEL = 0x8 | 0x80 | 0x100 | 0x200   # AcquireRelease | SubgroupMemory | WorkgroupMemory | CrossWorkgroupMemory
SUBGROUP_SIZE = 16   # the fixed sub-group size of the OpenCL module (lib/sycl: sub_group has 16 lanes)
BUILTIN_WORKGROUP_ID = 26
BUILTIN_LOCAL_INVOCATION_ID = 27
BUILTIN_GLOBAL_INVOCATION_ID = 28
DEC_BUILTIN = 11
DEC_SPEC_ID = 1
DEC_BLOCK = 2
DEC_OFFSET = 35

# The push constant struct: member name, IR-independent. The host (rt_vulkan.hpp) writes the same layout.
PUSH_MEMBERS = [
  [:closure, 8], [:statics, 8], [:stack, 8], [:local, 8], [:flag, 8],
  [:gx, 4], [:gy, 4], [:gz, 4], [:nx, 4], [:ny, 4], [:nz, 4],
  [:stack_bytes, 4], [:local_stride, 4], [:local_user, 4],
  [:ox, 4], [:oy, 4], [:oz, 4],   # the first work-group of this submit (a large grid is split into several)
  [:hlo, 8], [:hsize, 8], [:dbase, 8],   # the heap: its host address, its size, its device address (USM pointers)
]
PUSH_INDEX = {}
PUSH_OFFSET = []
PUSH_MEMBERS.each_with_index do |(name, size), i|
  PUSH_INDEX[name] = i
  off = i == 0 ? 0 : PUSH_OFFSET[i - 1] + PUSH_MEMBERS[i - 1][1]
  off = (off + size - 1) / size * size
  PUSH_OFFSET << off
end
PUSH_SIZE = (PUSH_OFFSET.last + PUSH_MEMBERS.last[1] + 15) / 16 * 16

# GLSL.std.450 instruction numbers for the SYCL math operations (detail::math_op in sycl.hpp).
GLSL_OF_MATH = {
  1 => 31, 2 => 27, 3 => 28, 4 => 13, 5 => 14, 6 => 15, 7 => 4, 8 => 8, 9 => 9, 10 => 3, 11 => 1, 12 => 32,
  13 => 29, 14 => 30, 15 => 16, 16 => 17, 17 => 18, 18 => 19, 19 => 20, 20 => 21,
  32 => 26, 33 => 37, 34 => 40, 35 => 25, 48 => 50, 49 => 43, 50 => 46,
  # OpenCL.std only (GLSL.std.450 has no erf, expm1 or log1p): codes 1000 and up, see OPENCL_ONLY
  21 => 1002, 22 => 1000, 23 => 1001,
}
# the OpenCL.std-only instructions of GLSL_OF_MATH (codes >= 1000), with their OpenCL.std opcodes: expm1 (22), log1p (40), erf (18)
OPENCL_ONLY = { 1000 => 22, 1001 => 40, 1002 => 18 }
# The OpenCL.std opcode of each GLSL.std.450 instruction the emitter uses (Kernel mode: OpenCL.std is the extended
# instruction set of OpenCL kernels, and Intel's compiler rejects GLSL.std.450 in a Kernel module). Same operation by
# name: round, trunc, fabs, ..., rsqrt (InverseSqrt), clamp (FClamp), mix (FMix), fma.
OPENCL_OF_GLSL = {
  1 => 55, 3 => 66, 4 => 23, 8 => 25, 9 => 12, 13 => 57, 14 => 14, 15 => 62, 16 => 3, 17 => 0, 18 => 6, 19 => 59,
  20 => 15, 21 => 63, 25 => 7, 26 => 48, 27 => 19, 28 => 37, 29 => 20, 30 => 38, 31 => 61, 32 => 56, 37 => 28,
  40 => 27, 43 => 95, 46 => 99, 50 => 26,
}
# libm builtins that libstdc++ calls for float arguments (the names of pathb-wgsl-emit.rb's LIBM_F32)
LIBM_GLSL = {
  "sqrtf" => 31, "expf" => 27, "logf" => 28, "sinf" => 13, "cosf" => 14, "tanf" => 15, "fabsf" => 4, "floorf" => 8,
  "ceilf" => 9, "truncf" => 3, "roundf" => 1, "exp2f" => 29, "log2f" => 30, "asinf" => 16, "acosf" => 17, "atanf" => 18,
  "sinhf" => 19, "coshf" => 20, "tanhf" => 21, "powf" => 26, "atan2f" => 25, "fminf" => 37, "fmaxf" => 40, "fmaf" => 50,
}
LIBM_GLSL.keys.each { |k| LIBM_GLSL["__builtin_" + k] = LIBM_GLSL[k] }

class Spv
  attr_reader :bound

  def initialize
    @bound = 1
    @caps = []
    @exts = []
    @anns = []      # OpDecorate, OpMemberDecorate
    @types = []     # types, constants, spec constants, global variables (in creation order: operands come first)
    @funcs = []     # function bodies (instruction lists)
    @memo = {}
    @glsl = nil
    @entries = []   # [model, function id, name, interface ids, local size ids]
    @modes = []
  end

  def id
    i = @bound
    @bound += 1
    i
  end

  def cap(c)
    @caps << c unless @caps.include?(c)
  end

  # OpExecutionMode of an entry point (mode, literal): the required sub-group size of a kernel
  def entry_mode(fid, mode, lit)
    @modes << [16, fid, mode, lit]
  end

  def ext(name)
    @exts << name unless @exts.include?(name)
  end

  def memo(key)
    return @memo[key] if @memo.key?(key)
    v = yield
    @memo[key] = v
    v
  end

  attr_accessor :kernel_cl

  def glsl_id
    @glsl ||= id
  end

  # the extended instruction set's name, and the opcode of GLSL instruction g in it
  def ext_set_name
    @kernel_cl ? "OpenCL.std" : "GLSL.std.450"
  end

  def ext_num(g)
    if g >= 1000
      raise Refused, "an OpenCL.std instruction (no GLSL.std.450 counterpart) outside a Kernel module" unless @kernel_cl
      return OPENCL_ONLY.fetch(g)
    end
    @kernel_cl ? OPENCL_OF_GLSL.fetch(g) : g
  end

  def decl(inst)
    @types << inst
  end

  def ann(inst)
    @anns << inst
  end

  def func(inst)
    @funcs << inst
  end

  def t_void
    memo([:void]) { i = id; decl([19, i]); i }
  end

  def t_bool
    memo([:bool]) { i = id; decl([20, i]); i }
  end

  def t_int(bits)
    memo([:int, bits]) { i = id; decl([21, i, bits, 0]); i }
  end

  def t_float(bits)
    cap(10) if bits == 64
    memo([:float, bits]) { i = id; decl([22, i, bits]); i }
  end

  def t_vec3
    memo([:vec3]) { i = id; decl([23, i, t_int(32), 3]); i }
  end

  # the type of a work-item builtin: a vector of uint in Vulkan; of size_t in OpenCL (a uint vector crashes Intel's
  # compiler, which takes the builtins as size_t: see docs/notes/gpu.md)
  def builtin_vec_t
    return t_vec3 unless @kernel_cl
    memo([:vec3_64]) { i = id; decl([23, i, t_int(64), 3]); i }
  end

  def t_ptr(sc, elem)
    memo([:ptr, sc, elem]) { i = id; decl([32, i, sc, elem]); i }
  end

  def t_fn(ret, params)
    memo([:fn, ret, params]) { i = id; decl([33, i, ret, *params]); i }
  end

  # Kernel mode: no Block and no Offset decorations (they need the Shader capability); the members follow natural alignment,
  # which is the layout the push block has (PUSH_OFFSET), so the host's struct is the same.
  def t_struct(members, offsets, name)
    memo([:struct, name]) do
      i = id
      decl([30, i, *members])
      unless @kernel_cl
        ann([OP_NAME_DECORATE, i, DEC_BLOCK])
        members.each_with_index { |_, k| ann([OP_MEMBER_DECORATE, i, k, DEC_OFFSET, offsets[k]]) }
      end
      i
    end
  end

  # constants: the value's bits as the type has them (64-bit values are two words, low first)
  def c_int(bits, v)
    t = t_int(bits)
    memo([:cint, bits, v & ((1 << bits) - 1)]) do
      i = id
      u = v & ((1 << bits) - 1)
      words = bits == 64 ? [u & 0xffffffff, u >> 32] : [u]
      decl([43, t, i, *words])
      i
    end
  end

  def c_u32(v)
    c_int(32, v)
  end

  def c_u64(v)
    c_int(64, v)
  end

  def c_float(bits, value)
    t = t_float(bits)
    v = value
    memo([:cfloat, bits, v]) do
      i = id
      raw = bits == 32 ? [v].pack("e").unpack("V*") : [v].pack("E").unpack("V*")
      decl([43, t, i, *raw])
      i
    end
  end

  # the float with the given bit pattern (infinities and NaN come through this)
  def c_float_bits(bits, pattern)
    t = t_float(bits)
    memo([:cfbits, bits, pattern]) do
      i = id
      words = bits == 32 ? [pattern & 0xffffffff] : [pattern & 0xffffffff, (pattern >> 32) & 0xffffffff]
      decl([43, t, i, *words])
      i
    end
  end

  def c_bool(v)
    t = t_bool
    memo([:cbool, v]) do
      i = id
      decl([v ? 41 : 42, t, i])
      i
    end
  end

  def spec_u32(spec_id, default)
    memo([:spec, spec_id]) do
      i = id
      decl([50, t_int(32), i, default])
      ann([71, i, DEC_SPEC_ID, spec_id])
      i
    end
  end

  # the work-group size as a BuiltIn WorkgroupSize constant (Vulkan has no LocalSizeId), built from the spec constants
  def workgroup_size(ids)
    memo([:wgsize, ids]) do
      i = id
      decl([51, t_vec3, i, *ids])
      ann([71, i, 11, 25])
      i
    end
  end

  def var(sc, ptr_type, name = nil)
    i = id
    decl([59, ptr_type, i, sc])
    i
  end

  # a global variable with a builtin decoration
  def builtin_input(builtin)
    memo([:builtin, builtin]) do
      v = var(SC_INPUT, t_ptr(SC_INPUT, builtin_vec_t))
      ann([71, v, DEC_BUILTIN, builtin])
      v
    end
  end

  def push_var
    memo([:push]) do
      u64 = t_int(64)
      u32 = t_int(32)
      members = PUSH_MEMBERS.map { |(_, size)| size == 8 ? u64 : u32 }
      st = t_struct(members, PUSH_OFFSET, :push)
      v = var(SC_PUSH_CONSTANT, t_ptr(SC_PUSH_CONSTANT, st))
      v
    end
  end

  def private_var(elem)
    memo([:private, elem]) { var(SC_PRIVATE, t_ptr(SC_PRIVATE, elem)) }
  end

  # an array type of len elements (OpTypeArray, the length a constant)
  def t_array(elem, len)
    memo([:array, elem, len]) { i = id; decl([28, i, elem, c_u32(len)]); i }
  end

  # the work-group static storage of a group: a module-scope Workgroup variable of `words` 32-bit words (the OpenCL local
  # memory the static accesses of the clones go to, see SFn#wgs_access)
  def wgs_var(words)
    memo([:wgsvar, words]) { var(SC_WORKGROUP, t_ptr(SC_WORKGROUP, t_array(t_int(32), words))) }
  end

  def add_entry(model, fid, name, iface, lsizes)
    @entries << [model, fid, name, iface, lsizes]
  end

  def finish(version = 0x00010500)
    out = [0x07230203, version, 0, 0, 0]
    body = []
    @caps.each { |c| body << [17, c] }
    @exts.each { |e| body << [10, *str_words(e)] }
    body << [11, glsl_id, *str_words(ext_set_name)]
    body << (@kernel_cl ? [14, 2, 2] : [14, 5348, 3])   # OpMemoryModel Physical64 OpenCL, or PhysicalStorageBuffer64 Vulkan
    @entries.each do |model, fid, name, iface, _|
      body << [15, model, fid, *str_words(name), *iface]
    end
    @modes.each { |m| body << m }
    out_words = []
    (body + @anns + @types + @funcs).each { |inst| out_words.concat(encode(inst)) }
    out[3] = @bound
    out + out_words
  end

  def encode(inst)
    op = inst[0]
    [((inst.length) << 16) | op] + inst[1..-1]
  end

  def str_words(s)
    bytes = s.bytes + [0]
    bytes << 0 while bytes.length % 4 != 0
    words = []
    (bytes.length / 4).times do |k|
      b = bytes[k * 4, 4]
      words << (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24))
    end
    words
  end
end

# ------------------------------------------------------------------ the module's shared state

class SpvModule
  attr_reader :spv, :push, :gid, :lid, :wid, :sp, :dead, :kernel_cl
  attr_accessor :stack_bytes, :fns, :fns_wgs, :defs, :subgroup_used, :wgs, :wgs_total, :wgs_var

  # kernel_cl: the OpenCL module. The push block, the stack pointer and the dead flag are parameters of every function
  # (per invocation) instead of module globals, which OpenCL kernels cannot have (Private, PushConstant).
  def initialize(spv, kernel_cl = false)
    @spv = spv
    @kernel_cl = kernel_cl
    @push = kernel_cl ? nil : spv.push_var
    @gid = spv.builtin_input(BUILTIN_GLOBAL_INVOCATION_ID)
    @lid = spv.builtin_input(BUILTIN_LOCAL_INVOCATION_ID)
    @wid = spv.builtin_input(BUILTIN_WORKGROUP_ID)
    @sp = kernel_cl ? nil : spv.private_var(spv.t_int(64))
    @dead = kernel_cl ? nil : spv.private_var(spv.t_int(32))
    @spec = [spv.spec_u32(0, 1), spv.spec_u32(1, 1), spv.spec_u32(2, 1)]
    # Kernel mode: the local size is the spec constants (set by the host), and WorkgroupSize as a builtin constant is
    # not valid in an OpenCL module (the validator wants a variable)
    spv.workgroup_size(@spec) unless kernel_cl
    @fns = {}
    @fns_wgs = {}      # the clones of the functions that a work-group-static kernel reaches (see emit_module)
    @defs = {}
    @stack_bytes = 0
    @wgs = {}          # [function name, slot name] => offset in the group's static local region (see wgs_layout)
    @wgs_total = 0
  end

  def spec_size(i)
    @spec[i]
  end

  # The struct of the push block (the same type whether it is a PushConstant variable or a pointer parameter).
  def push_struct_type
    members = PUSH_MEMBERS.map { |(_, size)| size == 8 ? @spv.t_int(64) : @spv.t_int(32) }
    @spv.t_struct(members, PUSH_OFFSET, :push)
  end

  # Kernel mode: the push block is a CrossWorkgroup pointer; Vulkan: a PushConstant variable.
  def push_class
    @kernel_cl ? SC_CROSSWG : SC_PUSH_CONSTANT
  end

  def spec_ids
    @spec
  end

  def pointer_tn(sc, t)
    @spv.t_ptr(sc, t)
  end
end

# ------------------------------------------------------------------ the IR types in SPIR-V

class SFn
  attr_reader :name, :fid, :ptypes, :ret, :frame, :callees, :ftype, :param_ids, :code, :vars, :param_lines

  def initialize(form, fid, mod, wgs_mode = false)
    @form = form
    @fid = fid
    @mod = mod
    @spv = mod.spv
    @wgs_mode = wgs_mode   # a clone for a kernel that uses a work-group static: its memory accesses route (see mem_access)
    @name = form ? form[1].to_s : "wrapper"
    @ptypes = []
    @ret = nil
    @slots = {}          # memory slot name => byte offset in the frame
    @wgs = {}            # work-group static slot name => offset in the group's static local region (wgs_layout)
    @locals = {}         # scalar slot name => [variable id, IR type]
    @frame = 0
    @body = []
    @vars = []           # OpVariable instructions of the first block
    @code = []           # the body
    @regs = {}           # "%N" => [:var, variable id, type] or [:val, id, type]
    @term = false
    @loops = []          # [{brk:, cont:, kind:}] innermost last
    @labels = {}         # IR label name => [block id, :brk or :cont]
    @pending_brk = nil
    @param_ids = []
    @callees = []
    setup if form
  end

  # The storage class of a memory access through a pointer made from an address: SC_PSB (Vulkan), SC_CROSSWG (Kernel).
  def psb_sc
    @mod.kernel_cl ? SC_CROSSWG : SC_PSB
  end

  # The per-invocation state a function reads: :push, :sp, :dead. Vulkan (no @state): the module globals. Kernel: the
  # function's parameters (compile), or the wrapper's locals (compile_wrapper).
  def state(name)
    return @state[name] if @state && @state.key?(name)
    return @mod.push if name == :push
    return @mod.sp if name == :sp
    @mod.dead
  end

  # The entry of a kernel: sets this invocation's stack (its slot in the stack region, by global linear index) and the
  # dead flag, then calls the kernel's IR function.
  def compile_wrapper(ir_fn)
    @param_lines = []
    if @mod.kernel_cl
      push_p = @spv.id
      @ftype = @spv.t_fn(@spv.t_void, [@spv.t_ptr(SC_CROSSWG, @mod.push_struct_type)])
      @param_lines << [55, @spv.t_ptr(SC_CROSSWG, @mod.push_struct_type), push_p]
      sp_v = var_decl(@spv.t_int(64))
      dead_v = var_decl(@spv.t_int(32))
      @state = { push: push_p, sp: sp_v, dead: dead_v }
    else
      @ftype = @spv.t_fn(@spv.t_void, [])
    end
    @ret_t = @spv.t_void
    gx = global_comp(0)
    gy = global_comp(1)
    gz = global_comp(2)
    # the stack is indexed over the dispatched grid (groups times local size), which can exceed the SYCL range
    t32 = @spv.t_int(32)
    t64 = @spv.t_int(64)
    sx = res(IMUL, t32, push_load(:nx, nil), @mod.spec_size(0))
    sy = res(IMUL, t32, push_load(:ny, nil), @mod.spec_size(1))
    lin = res(IADD, t32, res(IMUL, t32, res(IADD, t32, res(IMUL, t32, gz, sy), gy), sx), gx)
    sbytes = to_u64(push_load(:stack_bytes, nil), ["int", 4, false, false])
    base = push_load(:stack, nil)
    off = res(IMUL, t64, to_u64(lin, ["int", 4, false, false]), sbytes)
    top = res(IADD, t64, base, res(IADD, t64, off, sbytes))
    ins([62, state(:dead), @spv.c_u32(0)])
    ins([62, state(:sp), top])
    call_args = @state ? [state(:push), state(:sp), state(:dead)] : []
    ins([57, @spv.t_void, @spv.id, ir_fn, *call_args])
    term([253])
    self
  end

  def setup
    slots = []
    @form.each_with_index do |f, i|
      next if i < 2
      h = head_of(f)
      if h == "ret"
        t = parse_type(f[1])
        @ret = t[0] == "void" ? nil : t
      elsif h == "params"
        f.drop(1).each_with_index do |p, k|
          raise Refused, "variadic function #{@name}" if head_of(p) == "ellipsis"
          ph = head_of(p)
          if ph == "param"
            raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
            @ptypes << parse_type(p[3])
          elsif ph == "sret"
            raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
            @ptypes << ["ptr"]
          else
            raise Refused, "parameter form #{form_text(p)}"
          end
        end
      elsif h == "static" || h == "weak"
        nil
      elsif h == "slot"
        slots << f
      else
        @body << f
      end
    end
    fold_fnptr_slots(@body, slots)
    direct = {}
    escaped = {}
    @body.each { |s| scan_slots(s, direct, escaped) }
    off = 0
    slots.each do |f|
      sname = f[1].to_s
      if @mod.wgs && @mod.wgs.key?([@name, sname])
        @wgs[sname] = @mod.wgs[[@name, sname]]
        next
      end
      size = f.length == 5 ? as_int(f[3]) : 4
      align = f.length == 5 ? as_int(f[4]) : 4
      ty = scalar_form?(f[2]) ? parse_type(f[2]) : nil
      uses = direct[sname] || []
      if ty && ty[0] != "void" && !escaped[sname] && uses.all? { |u| u == ty }
        @locals[sname] = [nil, ty]   # the variable is declared when the function is compiled
      else
        align = 8 if align < 8
        off = (off + align - 1) / align * align
        @slots[sname] = off
        off += size
      end
    end
    @frame = (off + 15) / 16 * 16
    @callees = collect_calls(@form, []).select { |c| @mod.defs.key?(c) }.uniq
  end

  # ---- the instruction stream

  def ins(inst)
    return if @term
    @code << inst
  end

  def term(inst)
    return if @term
    @code << inst
    @term = true
  end

  def label(l)
    @code << [248, l]
    @term = false
  end

  def res(opcode, rtype, *ops)
    i = @spv.id
    ins([opcode, rtype, i, *ops])
    i
  end

  def new_label
    @spv.id
  end

  def branch(l)
    term([249, l])
  end

  def cond_branch(c, t, f)
    term([250, c, t, f])
  end

  def var_decl(t)
    pt = @spv.t_ptr(SC_FUNCTION, t)
    v = @spv.id
    @vars << [59, pt, v, SC_FUNCTION]
    v
  end

  def zero_of(t)
    if t[0] == "void"
      nil
    else
      st = sty(t)
      if t[0] == "int" && t[3]
        @spv.c_bool(false)
      elsif t[0] == "float"
        t[1] == 4 ? @spv.c_float(32, 0.0) : @spv.c_float(64, 0.0)
      else
        @spv.c_int(t[0] == "ptr" ? 64 : (t[1] * 8 > 32 ? 64 : 32), 0)
      end
    end
  end

  # the SPIR-V type of an IR scalar: bool, 32-bit integers (1, 2 and 4 bytes, canonical), 64-bit integers and pointers, floats
  def sty(t)
    case t[0]
    when "void" then @spv.t_void
    when "ptr" then @spv.t_int(64)
    when "int"
      return @spv.t_bool if t[3]
      t[1] == 8 ? @spv.t_int(64) : @spv.t_int(32)
    when "float"
      @spv.t_float(t[1] * 8)
    else raise Refused, "value of type #{t[0]}"
    end
  end

  def wide?(t)
    t[0] == "ptr" || (t[0] == "int" && !t[3] && t[1] == 8) || (t[0] == "float" && t[1] == 8)
  end

  # ---- operands: [id, IR type]

  def push_load(member, t)
    idx = PUSH_INDEX.fetch(member)
    ptr_t = @spv.t_ptr(@mod.push_class, sty_of_push(member))
    p = res(65, ptr_t, state(:push), @spv.c_u32(idx))
    res(61, sty_of_push(member), p)
  end

  def sty_of_push(member)
    PUSH_MEMBERS[PUSH_INDEX.fetch(member)][1] == 8 ? @spv.t_int(64) : @spv.t_int(32)
  end

  # USM pointers. A pointer in memory is the host's address of its target (the host writes and reads them); in a register it is
  # the device's. A load translates host to device and a store translates device to host. A value already in the other form
  # is left alone: the host heap and the device heap do not overlap (the runtime checks), so a device address is never in the
  # host range. On a driver whose device addresses are its host addresses both translations are the identity.
  def ptr_to_device(v)
    hlo, hsize, dbase = push_load(:hlo, nil), push_load(:hsize, nil), push_load(:dbase, nil)
    inside = res(176, @spv.t_bool, res(ISUB, @spv.t_int(64), v, hlo), hsize)
    moved = res(IADD, @spv.t_int(64), v, res(ISUB, @spv.t_int(64), dbase, hlo))
    res(169, @spv.t_int(64), inside, moved, v)
  end

  def ptr_to_host(v)
    hlo, hsize, dbase = push_load(:hlo, nil), push_load(:hsize, nil), push_load(:dbase, nil)
    inside = res(176, @spv.t_bool, res(ISUB, @spv.t_int(64), v, dbase), hsize)
    moved = res(ISUB, @spv.t_int(64), v, res(ISUB, @spv.t_int(64), dbase, hlo))
    res(169, @spv.t_int(64), inside, moved, v)
  end

  def builtin_component(var, k)
    if @mod.kernel_cl
      v = res(61, @spv.builtin_vec_t, var)
      c = res(81, @spv.t_int(64), v, k)
      return res(113, @spv.t_int(32), c)   # OpUConvert: the IR's 32-bit index
    end
    v = res(61, @spv.t_vec3, var)
    res(81, @spv.t_int(32), v, k)
  end

  # the global invocation index in dimension k: the id within this submit, plus the submit's first group times the local size
  def global_comp(k)
    g = builtin_component(@mod.gid, k)
    off = push_load([:ox, :oy, :oz][k], nil)
    res(IADD, @spv.t_int(32), g, res(IMUL, @spv.t_int(32), off, @mod.spec_size(k)))
  end

  # the work-group index in dimension k over the whole grid
  def group_comp(k)
    w = builtin_component(@mod.wid, k)
    res(IADD, @spv.t_int(32), w, push_load([:ox, :oy, :oz][k], nil))
  end

  def operand(x)
    if x.is_a?(String) && x.start_with?("%")
      r = @regs[x]
      raise BadIR, "register #{x} is used before it is set" if r.nil?
      return [r[1], r[2]] if r[0] == :val
      return [res(61, sty(r[2]), r[1]), r[2]]
    end
    h = head_of(x)
    if h == "const"
      ty = parse_type(x[1])
      if ty[0] == "float"
        ft = float_text(x[2].to_s)
        return [float_const(ty[1] * 8, ft), ty]
      end
      if ty[0] == "int" && ty[3]
        return [@spv.c_bool(as_int(x[2]) != 0), ty]
      end
      v = as_int(x[2])
      bits = wide?(ty) ? 64 : 32
      return [@spv.c_int(bits, v), ty]
    end
    return [@spv.c_u64(0), ["ptr"]] if h == "null"
    return operand(x[2]) if h == "sret" || h == "byval"
    if x.is_a?(IRSym) && x.sig == "$"
      if @wgs.key?(x.name)
        # a work-group static: the group's region after the scratch tail (one object per group)
        lu = res(IADD, @spv.t_int(64), local_base, to_u64(push_load(:local_user, nil), ["int", 4, false, false]))
        return [res(IADD, @spv.t_int(64), lu, @spv.c_u64(1024 + @wgs[x.name])), ["ptr"]]
      end
      off = @slots[x.name]
      raise Refused, "address of the scalar slot #{x.name}" if off.nil? && @locals.key?(x.name)
      raise BadIR, "slot #{x.name} is not declared" if off.nil?
      return [res(IADD, @spv.t_int(64), frame_base, @spv.c_u64(off)), ["ptr"]]
    end
    if x.is_a?(IRSym) && x.sig == "@"
      off = @mod.static_offset_of(x.name)
      return [res(IADD, @spv.t_int(64), push_load(:statics, nil), @spv.c_u64(off)), ["ptr"]]
    end
    raise Refused, "address of function #{x.name}" if x.is_a?(IRSym) && x.sig == "&"
    raise Refused, "operand #{form_text(x)}"
  end

  def float_const(bits, ft)
    return @spv.c_float_bits(bits, ft[1]) if ft.is_a?(Array)
    @spv.c_float(bits, ft.to_f)
  end

  def float_text(text)
    if text == "+Infinity" || text == "Infinity"
      return [:bits, 0x7f800000]
    elsif text == "-Infinity"
      return [:bits, 0xff800000]
    end
    ok = text.count("0123456789") > 0
    text.each_char { |c| ok = false unless "0123456789.eE+-".include?(c) }
    raise Refused, "float constant #{text}" unless ok
    text
  end

  # the current frame's address (the frame variable holds it)
  def frame_base
    res(61, @spv.t_int(64), @frame_var)
  end

  # ---- integer and float helpers (all results are SPIR-V values of the IR type's sty)

  IADD = 128
  ISUB = 130
  IMUL = 132

  # a narrow integer kept in 32 bits: sign-extended (signed) or zero-extended (unsigned) from its width
  def canon(id, t)
    return id unless t[0] == "int" && !t[3] && t[1] < 4
    sh = 32 - t[1] * 8
    l = res(196, @spv.t_int(32), id, @spv.c_u32(sh))
    res(t[2] ? 195 : 194, @spv.t_int(32), l, @spv.c_u32(sh))
  end

  def canon_u(id, t)
    return id unless t[0] == "int" && !t[3] && t[1] < 4 && !t[2]
    mask = (1 << (t[1] * 8)) - 1
    res(199, @spv.t_int(32), id, @spv.c_u32(mask))
  end

  def bool_to_u32(b)
    res(169, @spv.t_int(32), b, @spv.c_u32(1), @spv.c_u32(0))
  end

  def u32_of(id, ty)
    if ty[0] == "int" && ty[3]
      return bool_to_u32(id)
    end
    return id if !wide?(ty)
    res(113, @spv.t_int(32), id)
  end

  def to_u64(id, ty)
    return id if wide?(ty) || ty[0] == "ptr"
    if ty[0] == "int" && ty[3]
      return res(113, @spv.t_int(64), bool_to_u32(id))
    end
    if ty[2]
      res(114, @spv.t_int(64), id)
    else
      res(113, @spv.t_int(64), id)
    end
  end

  def int_const_of(t, v)
    @spv.c_int(wide?(t) ? 64 : 32, v)
  end

  # the trap helper: set the flag to code, mark the invocation dead, return zero
  def trap(code)
    flag_ptr = res(120, @spv.t_ptr(psb_sc, @spv.t_int(32)), push_load(:flag, nil))
    ins([239, @spv.t_int(32), @spv.id, flag_ptr, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED), @spv.c_u32(code)]) # OpAtomicUMax
    store_var(state(:dead), @spv.c_u32(1), @spv.t_int(32))
    emit_return(nil) unless @cont_exit
  end

  # In a loop's step (the continue construct) a dead invocation must not return from the middle of the construct: SPIR-V wants
  # the back-edge block to post-dominate the continue target, and branches out of a selection only to its merge. So the
  # step's checks fall through, and after each one a branch (outside any selection) goes to the back-edge block.
  def dead_exit_to_back
    d = res(61, @spv.t_int(32), state(:dead))
    c = res(171, @spv.t_bool, d, @spv.c_u32(0))
    nxt = new_label
    cond_branch(c, @cont_exit, nxt)
    label(nxt)
  end

  def store_var(v, val, t)
    ins([62, v, val])
  end

  def emit_return(val)
    if @frame > 0
      old = res(61, @spv.t_int(64), @oldsp_var)
      ins([62, state(:sp), old])
    end
    if @ret.nil?
      term([253])
    else
      term([254, val || zero_of(@ret)])
    end
  end

  # if (cond) trap(code)
  def trap_if(cond, code)
    t = new_label
    m = new_label
    ins([247, m, 0])
    cond_branch(cond, t, m)
    label(t)
    trap(code)
    branch(m) if @cont_exit
    label(m)
    dead_exit_to_back if @cont_exit
  end

  def check_dead_after_call
    return dead_exit_to_back if @cont_exit
    d = res(61, @spv.t_int(32), state(:dead))
    c = res(171, @spv.t_bool, d, @spv.c_u32(0))
    t = new_label
    m = new_label
    ins([247, m, 0])
    cond_branch(c, t, m)
    label(t)
    if @cont_exit
      branch(m)
    else
      emit_return(nil)
    end
    label(m)
    dead_exit_to_back if @cont_exit
  end

  # ---- memory

  def psb_ptr(t)
    @spv.t_ptr(psb_sc, sty(t))
  end

  def addr_ptr(addr, t)
    res(120, psb_ptr(t), addr)
  end

  def aligned_word_addr(addr)
    mask = @spv.c_u64(0xfffffffffffffffc)
    res(199, @spv.t_int(64), addr, mask)
  end

  def byte_shift(addr)
    low = res(199, @spv.t_int(64), addr, @spv.c_u64(3))
    l32 = res(113, @spv.t_int(32), low)
    res(132, @spv.t_int(32), l32, @spv.c_u32(8))
  end

  # the word that holds the byte at addr, and the shift of the byte in it
  def load_word(addr)
    wp = res(120, @spv.t_ptr(psb_sc, @spv.t_int(32)), aligned_word_addr(addr))
    res(61, @spv.t_int(32), wp, 2, 4) # Aligned 4
  end

  def heap_load(addr, t)
    if t[0] == "int" && (t[1] <= 2 || t[3])
      w = load_word(addr)
      sh = byte_shift(addr)
      bits = t[3] ? 8 : t[1] * 8
      v = res(194, @spv.t_int(32), w, sh)
      v = res(199, @spv.t_int(32), v, @spv.c_u32((1 << bits) - 1))
      return res(171, @spv.t_bool, v, @spv.c_u32(0)) if t[3]
      return canon(v, t)
    end
    p = addr_ptr(addr, t)
    align = t[0] == "ptr" ? 8 : t[1]
    v = res_load(p, sty(t), align)
    t[0] == "ptr" ? ptr_to_device(v) : v
  end

  # ---- work-group statics (wgs_mode clones). The static region of the group is the Workgroup variable @mod.wgs_var; an access
  # whose address lies in the region (sbase = the group's local base + the scratch tail, the length wgs_total) goes to the
  # variable, any other to the heap path. Routing is by address, so every access to a static takes the same storage.
  def mem_load(addr, t)
    return heap_load(addr, t) unless @wgs_mode
    raise Refused, "a work-group static access in #{@name} without the Workgroup variable" unless @mod.wgs_var
    rel, inside = wgs_range(addr)
    b_in, b_out, merge = new_label, new_label, new_label
    ins([247, merge, 0])   # OpSelectionMerge
    cond_branch(inside, b_in, b_out)
    label(b_in)
    vin = wgs_load_val(rel, t)
    vin = ptr_to_device(vin) if t[0] == "ptr"
    branch(merge)
    label(b_out)
    vout = heap_load(addr, t)
    branch(merge)
    label(merge)
    res(245, sty(t), vin, b_in, vout, b_out)   # OpPhi
  end

  def mem_store(addr, t, v)
    return heap_store(addr, t, v) unless @wgs_mode
    raise Refused, "a work-group static access in #{@name} without the Workgroup variable" unless @mod.wgs_var
    rel, inside = wgs_range(addr)
    b_in, b_out, merge = new_label, new_label, new_label
    ins([247, merge, 0])   # OpSelectionMerge
    cond_branch(inside, b_in, b_out)
    label(b_in)
    wgs_store_val(rel, t, t[0] == "ptr" ? ptr_to_host(v) : v)
    branch(merge)
    label(b_out)
    heap_store(addr, t, v)
    branch(merge)
    label(merge)
  end

  # whether addr lies in the group's static region: its offset rel (unsigned, below wgs_total) and the test
  def wgs_range(addr)
    t64 = @spv.t_int(64)
    sbase = res(IADD, t64, local_base, to_u64(push_load(:local_user, nil), ["int", 4, false, false]))
    sbase = res(IADD, t64, sbase, @spv.c_u64(1024))
    rel = res(ISUB, t64, addr, sbase)
    [rel, res(176, @spv.t_bool, rel, @spv.c_u64(@mod.wgs_total))]
  end

  # the pointer to the 32-bit word that holds the bytes at offset rel + 4 * word_off of the static region
  def wgs_word(rel, word_off = 0)
    t64 = @spv.t_int(64)
    r = word_off == 0 ? rel : res(IADD, t64, rel, @spv.c_u64(4 * word_off))
    widx = res(113, @spv.t_int(32), res(194, t64, r, @spv.c_u64(2)))
    res(65, @spv.t_ptr(SC_WORKGROUP, @spv.t_int(32)), @mod.wgs_var, widx)
  end

  # the bytes an access of type t covers: 1 for bool, 8 for pointers
  def wgs_bytes(t)
    return 8 if t[0] == "ptr"
    return 1 if t[0] == "int" && t[3]
    t[1]
  end

  def wgs_load_val(rel, t)
    t32, t64 = @spv.t_int(32), @spv.t_int(64)
    n = wgs_bytes(t)
    if n == 8
      lo = res(113, t64, res(61, t32, wgs_word(rel, 0)))
      hi = res(113, t64, res(61, t32, wgs_word(rel, 1)))
      v = res(197, t64, lo, res(196, t64, hi, @spv.c_u64(32)))
      return t[0] == "float" ? res(124, sty(t), v) : v
    end
    w = res(61, t32, wgs_word(rel))
    if n == 4
      return t[0] == "float" ? res(124, sty(t), w) : w
    end
    bits = n * 8
    v = res(194, t32, w, byte_shift(rel))
    v = res(199, t32, v, @spv.c_u32((1 << bits) - 1))
    return res(171, @spv.t_bool, v, @spv.c_u32(0)) if t[0] == "int" && t[3]
    canon(v, t)
  end

  def wgs_store_val(rel, t, v)
    t32, t64 = @spv.t_int(32), @spv.t_int(64)
    n = wgs_bytes(t)
    if n == 8
      u = t[0] == "float" ? res(124, t64, v) : v
      ins([62, wgs_word(rel, 0), res(113, t32, u)])
      ins([62, wgs_word(rel, 1), res(113, t32, res(194, t64, u, @spv.c_u64(32)))])
      return
    end
    if n == 4
      u = t[0] == "float" ? res(124, t32, v) : v
      ins([62, wgs_word(rel), u])
      return
    end
    # a sub-word store: the bits of the word outside the access are kept; the update is atomic, as the other items of the
    # group may write the same word
    bits = n * 8
    mask = (1 << bits) - 1
    vv = t[0] == "int" && t[3] ? bool_to_u32(v) : u32_of(v, t)
    vv = res(199, t32, vv, @spv.c_u32(mask))
    sh = byte_shift(rel)
    wp = wgs_word(rel)
    clear = res(200, t32, res(196, t32, @spv.c_u32(mask), sh))
    ins([240, t32, @spv.id, wp, @spv.c_u32(SCOPE_WORKGROUP), @spv.c_u32(SEM_RELAXED), clear])   # OpAtomicAnd
    ins([241, t32, @spv.id, wp, @spv.c_u32(SCOPE_WORKGROUP), @spv.c_u32(SEM_RELAXED), res(196, t32, vv, sh)])   # OpAtomicOr
  end

  def res_load(p, rtype, align)
    i = @spv.id
    ins([61, rtype, i, p, 2, align])
    i
  end

  def heap_store(addr, t, v)
    if t[0] == "int" && (t[1] <= 2 || t[3])
      bits = t[3] ? 8 : t[1] * 8
      mask = (1 << bits) - 1
      vv = t[3] ? bool_to_u32(v) : u32_of(v, t)
      vv = res(199, @spv.t_int(32), vv, @spv.c_u32(mask))
      sh = byte_shift(addr)
      wp = res(120, @spv.t_ptr(psb_sc, @spv.t_int(32)), aligned_word_addr(addr))
      clear = res(196, @spv.t_int(32), @spv.c_u32(mask), sh)
      clear = res(200, @spv.t_int(32), clear)
      ins([240, @spv.t_int(32), @spv.id, wp, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED), clear]) # OpAtomicAnd
      shifted = res(196, @spv.t_int(32), vv, sh)
      ins([241, @spv.t_int(32), @spv.id, wp, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED), shifted]) # OpAtomicOr
      return
    end
    p = addr_ptr(addr, t)
    align = t[0] == "ptr" ? 8 : t[1]
    v = ptr_to_host(v) if t[0] == "ptr"
    ins([62, p, v, 2, align])
  end

  # ---- the atomic compare-and-swap loop of a float atomic (WebGPU and Vulkan lack a float min/max)
  def float_atomic(p_addr, t, v, op)
    raise Refused, "an atomic on memory in #{@name}, which may be a work-group static (not routed)" if @wgs_mode
    expected = var_decl(@spv.t_int(32))
    wp = res(120, @spv.t_ptr(psb_sc, @spv.t_int(32)), p_addr)
    ins([62, expected, res(61, @spv.t_int(32), wp, 2, 4)])
    hdr = new_label
    body = new_label
    cont = new_label
    merge = new_label
    after = new_label
    t1 = new_label
    branch(hdr)
    label(hdr)
    ins([246, merge, cont, 0])
    branch(body)
    label(body)
    old = res(61, @spv.t_int(32), expected)
    f = res(124, @spv.t_float(32), old)
    nf = op == :add ? res(129, @spv.t_float(32), f, v) : res(12, @spv.t_float(32), @spv.glsl_id, @spv.ext_num(op == :min ? 37 : 40), f, v)
    nb = res(124, @spv.t_int(32), nf)
    r = res_cas(wp, expected, nb)
    ok = res(170, @spv.t_bool, r, old)
    ins([247, after, 0])
    cond_branch(ok, merge, t1)
    label(t1)
    ins([62, expected, r])
    branch(after)
    label(after)
    branch(cont)
    label(cont)
    branch(hdr)
    label(merge)
  end

  def res_cas(wp, expected_var, desired)
    e = res(61, @spv.t_int(32), expected_var)
    res(230, @spv.t_int(32), wp, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED), @spv.c_u32(SEM_RELAXED), desired, e)
  end

  # ---- expressions

  def rval(x, dty)
    h = head_of(x)
    case h
    when "load", "load.v"
      ty = parse_type(x[1])
      if x[2].is_a?(IRSym) && x[2].sig == "$" && @locals.key?(x[2].name)
        return [res(61, sty(ty), @locals[x[2].name][0]), ty]
      end
      a, _ = operand(x[2])
      if ty[0] == "void"
        raise Refused, "load of void"
      end
      if ty[0] == "int" && ty[3]
        return [mem_load(a, ty), ty]
      end
      [mem_load(a, ty), ty]
    when "bitcast"
      v, vty = operand(x[2])
      raise Refused, "bitcast of a #{vty[0]}" unless vty[0] == "ptr"
      [v, ["ptr"]]
    when "offset"
      b, _ = operand(x[1])
      [res(IADD, @spv.t_int(64), b, @spv.c_u64(as_int(x[2]))), ["ptr"]]
    when "index"
      b, _ = operand(x[1])
      i, ity = operand(x[2])
      size = x[3].is_a?(String) && x[3].start_with?("%") ? operand(x[3])[0] : @spv.c_u64(as_int(x[3]))
      off = to_i64(i, ity)
      [res(IADD, @spv.t_int(64), b, res(IMUL, @spv.t_int(64), off, size)), ["ptr"]]
    when "pdiff"
      a, _ = operand(x[1])
      b, _ = operand(x[2])
      d = res(ISUB, @spv.t_int(64), a, b)
      [res(135, @spv.t_int(64), d, @spv.c_u64(as_int(x[3]))), ["int", 8, true, false]]
    when "wadd", "wsub", "wmul"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      op = { "wadd" => IADD, "wsub" => ISUB, "wmul" => IMUL }[h]
      [canon(res(op, sty(ty), a, b), ty), ty]
    when "wneg"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      [canon(res(ISUB, sty(ty), zero_of(ty), a), ty), ty]
    when "cdiv", "crem"
      ty = parse_type(x[1])
      [checked_div(h, ty, x[2], x[3]), ty]
    when "cshl", "cshr"
      ty = parse_type(x[1])
      [checked_shift(h, ty, x[2], x[3]), ty]
    when "and", "or", "xor"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      if ty[0] == "int" && ty[3]
        op = { "and" => 167, "or" => 166, "xor" => 165 }[h]
        return [res(op, @spv.t_bool, a, b), ty]
      end
      op = { "and" => 199, "or" => 197, "xor" => 198 }[h]
      [res(op, sty(ty), a, b), ty]
    when "not"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      if ty[0] == "int" && ty[3]
        return [res(168, @spv.t_bool, a), ty]
      end
      [canon(res(200, sty(ty), a), ty), ty]
    when "fadd", "fsub", "fmul", "fdiv"
      ty = parse_type(x[1])
      raise Refused, "#{h} on #{ty[0]}" unless ty[0] == "float"
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      op = { "fadd" => 129, "fsub" => 131, "fmul" => 133, "fdiv" => 136 }[h]
      [res(op, sty(ty), a, b), ty]
    when "fneg"
      ty = parse_type(x[1])
      raise Refused, "fneg on #{ty[0]}" unless ty[0] == "float"
      a, _ = operand(x[2])
      [res(127, sty(ty), a), ty]
    when "iconv"
      ty = parse_type(x[1])
      a, aty = operand(x[2])
      [int_convert(ty, a, aty), ty]
    when "p2i"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      [int_convert(ty, a, ["ptr"]), ty]
    when "i2p"
      a, aty = operand(x[2])
      [to_u64(a, aty), ["ptr"]]
    when "fconv"
      ty = parse_type(x[1])
      a, aty = operand(x[2])
      raise BadIR, "fconv of a #{aty[0]}" unless aty[0] == "float"
      return [a, ty] if ty[1] == aty[1]
      [res(115, sty(ty), a), ty]
    when "i2f", "u2f"
      ty = parse_type(x[1])
      raise Refused, "#{h} to #{ty[0]}" unless ty[0] == "float"
      a, aty = operand(x[2])
      if aty[0] == "int" && aty[3]   # a bool holds 0 or 1: it converts as the unsigned 0 or 1 (0.0 or 1.0)
        a = bool_to_u32(a)
        aty = ["int", 4, false, false]
      end
      v = h == "i2f" && aty[0] == "int" && aty[2] ? res(111, sty(ty), a) : res(112, sty(ty), a)
      [v, ty]
    when "cf2i"
      ty = parse_type(x[1])
      a, aty = operand(x[2])
      [float_to_int(ty, a, aty), ty]
    when "lt", "le", "gt", "ge", "eq", "ne", "lt.s", "le.s", "gt.s", "ge.s", "eq.s", "ne.s",
         "lt.u", "le.u", "gt.u", "ge.u", "eq.u", "ne.u", "lt.f", "le.f", "gt.f", "ge.f", "eq.f", "ne.f"
      op = h.split(".")[0]
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      [compare(op, ty, a, b), ["int", 4, false, true]]
    when "call"
      r = call_expr(x)
      raise Refused, "value of a call of a void function" if r.nil?
      r
    when "const"
      ty = parse_type(x[1])
      operand(x)
    else
      raise Refused, "expression #{h || form_text(x)}"
    end
  end

  def to_i64(id, ty)
    return id if ty[0] == "ptr" || (ty[0] == "int" && ty[1] == 8)
    res(ty[2] ? 114 : 113, @spv.t_int(64), id)
  end

  def compare(op, ty, a, b)
    if ty[0] == "int" && ty[3]
      raise Refused, "bool comparison #{op}" unless op == "eq" || op == "ne"
      return res(op == "eq" ? 164 : 165, @spv.t_bool, a, b)
    end
    if ty[0] == "float"
      code = { "lt" => 184, "le" => 188, "gt" => 186, "ge" => 190, "eq" => 180, "ne" => 183 }[op]
      return res(code, @spv.t_bool, a, b)
    end
    signed = ty[0] == "int" && ty[2]
    code = { "lt" => signed ? 177 : 176, "le" => signed ? 179 : 178, "gt" => signed ? 173 : 172,
             "ge" => signed ? 175 : 174, "eq" => 170, "ne" => 171 }[op]
    res(code, @spv.t_bool, a, b)
  end

  def checked_div(h, ty, xa, xb)
    raise Refused, "#{h} on #{ty[0]}" unless int_ty?(ty)
    a, _ = operand(xa)
    b, _ = operand(xb)
    zero = int_const_of(ty, 0)
    if ty[2]
      bits = wide?(ty) ? 64 : 32
      minv = ty[1] == 8 ? -(1 << 63) : -(1 << (ty[1] * 8 - 1))
      mn = int_const_of(ty, minv)
      m1 = int_const_of(ty, -1)
      c0 = res(170, @spv.t_bool, b, zero)
      q1 = res(170, @spv.t_bool, b, m1)
      q2 = res(170, @spv.t_bool, a, mn)
      q = res(167, @spv.t_bool, q1, q2)
      c = res(166, @spv.t_bool, c0, q)
    else
      c = res(170, @spv.t_bool, b, zero)
    end
    trap_if(c, 1)
    # cdiv: the quotient; crem: the remainder (truncated toward zero, the sign of the dividend, as C has it)
    code = ty[2] ? (h == "cdiv" ? 135 : 138) : (h == "cdiv" ? 134 : 137)
    canon(res(code, sty(ty), a, b), ty)
  end

  def checked_shift(h, ty, xa, xb)
    raise Refused, "#{h} on #{ty[0]}" unless int_ty?(ty)
    a, _ = operand(xa)
    c, cty = operand(xb)
    raise Refused, "shift count of type #{cty[0]}" unless int_ty?(cty)
    width = ty[1] == 8 ? 64 : ty[1] * 8
    if wide?(cty)
      trap_if(res(172, @spv.t_bool, c, @spv.c_u64(width)), 2)
    else
      trap_if(res(172, @spv.t_bool, c, @spv.c_u32(width)), 2)
    end
    # The count has the width of the shifted value. A mixed-width shift (a 32-bit count of a 64-bit value, as the IR gives
    # `x >> 32` on a u64) is valid SPIR-V, but the OpenCL device compiler drops the stores that depend on its result. The
    # count is below the width here (checked above), so narrowing it is exact.
    if wide?(ty) && !wide?(cty)
      c = res(113, @spv.t_int(64), c)
    elsif !wide?(ty) && wide?(cty)
      c = res(113, @spv.t_int(32), c)
    end
    if h == "cshl"
      canon(res(196, sty(ty), a, c), ty)
    else
      op = ty[2] ? 195 : 194
      canon(res(op, sty(ty), a, c), ty)
    end
  end

  # iconv: integer to integer (sign-extend from a signed source, zero-extend from an unsigned one, truncate to narrower)
  def int_convert(ty, a, aty)
    if ty[0] == "int" && ty[3]
      return res(170, @spv.t_bool, a, zero_of(aty)) if aty[0] == "int" && !aty[3]
      raise Refused, "bool conversion"
    end
    raise Refused, "iconv to #{ty[0]}" unless ty[0] == "int" || ty[0] == "ptr"
    src = aty[0] == "int" && aty[3] ? bool_to_u32(a) : a
    sw = aty[0] == "int" && aty[3] ? 4 : (aty[0] == "ptr" ? 8 : aty[1])
    signed = aty[0] == "int" && aty[2] && !aty[3]
    dw = ty[0] == "ptr" ? 8 : ty[1]
    if sw == 8 && dw == 8
      return a
    end
    if sw < 8 && dw == 8
      return res(signed ? 114 : 113, @spv.t_int(64), src)
    end
    if sw == 8 && dw < 8
      v = res(113, @spv.t_int(32), a)
      return canon(v, ty)
    end
    canon(src, ty)
  end

  # cf2i: C truncation; the flag is set (code 6) on NaN and on values out of range (the bounds are exact in the source type)
  def float_to_int(ty, a, aty)
    raise Refused, "cf2i to #{ty[0]}" unless int_ty?(ty)
    raise BadIR, "cf2i of a #{aty[0]}" unless aty[0] == "float"
    bits = ty[1] * 8
    fbits = aty[1] * 8
    if ty[2]
      lo = -(2 ** (bits - 1)).to_f
      hi = (2 ** (bits - 1)).to_f
      exact_below = (fbits == 64 && bits <= 53) || (fbits == 32 && bits <= 24)
      lo_op, lo_v = exact_below ? [186, lo - 1.0] : [190, lo]
    else
      lo_op, lo_v = 186, -1.0
      hi = (2 ** bits).to_f
    end
    lo_c = aty[1] == 4 ? @spv.c_float(32, lo_v) : @spv.c_float(64, lo_v)
    hi_c = aty[1] == 4 ? @spv.c_float(32, hi) : @spv.c_float(64, hi)
    p1 = res(lo_op, @spv.t_bool, a, lo_c)
    p2 = res(184, @spv.t_bool, a, hi_c)
    ok = res(167, @spv.t_bool, p1, p2)
    trap_if(res(168, @spv.t_bool, ok), 6)
    v = ty[2] ? res(110, sty(ty), a) : res(109, sty(ty), a)
    canon(v, ty)
  end

  # ---- calls and intrinsics

  def call_expr(x)
    ty = parse_type(x[1])
    callee = x[2]
    raise Refused, "indirect call" unless callee.is_a?(IRSym) && callee.sig == "&"
    name = callee.name
    args = x.drop(3)
    case name
    when "__nfcxx_sycl_gid_x", "__nfcxx_sycl_gid_y", "__nfcxx_sycl_gid_z"
      return [global_comp("xyz".index(name[-1])), ["int", 4, false, false]]
    when "__nfcxx_sycl_lid_x", "__nfcxx_sycl_lid_y", "__nfcxx_sycl_lid_z"
      return [builtin_component(@mod.lid, "xyz".index(name[-1])), ["int", 4, false, false]]
    when "__nfcxx_sycl_group_x", "__nfcxx_sycl_group_y", "__nfcxx_sycl_group_z"
      return [group_comp("xyz".index(name[-1])), ["int", 4, false, false]]
    when "__nfcxx_sycl_grange_x", "__nfcxx_sycl_grange_y", "__nfcxx_sycl_grange_z"
      return [push_load(:"g#{name[-1]}", nil), ["int", 4, false, false]]
    when "__nfcxx_sycl_lrange_x", "__nfcxx_sycl_lrange_y", "__nfcxx_sycl_lrange_z"
      return [@mod.spec_size("xyz".index(name[-1])), ["int", 4, false, false]]
    when "__nfcxx_sycl_closure"
      return [push_load(:closure, nil), ["ptr"]]
    when "__nfcxx_sycl_local_base"
      return [local_base, ["ptr"]]
    when "__nfcxx_sycl_scratch"
      lu = res(IADD, @spv.t_int(64), local_base, to_u64(push_load(:local_user, nil), ["int", 4, false, false]))
      return [lu, ["ptr"]]
    when "__nfcxx_sycl_sg_shuffle_u32", "__nfcxx_sycl_sg_shuffle_xor_u32"
      # sub-group lanes exchange a 32-bit word: OpSubgroupShuffleINTEL (the value of lane args[1]) or OpSubgroupShuffleXorINTEL
      # (lane ^ args[1]), SPV_INTEL_subgroups. The OpenCL 2.2 validation environment has no GroupNonUniform (SPIR-V 1.3), so
      # this is the shuffle that the OpenCL module can carry. The module is an OpenCL module: its kernels get the
      # SubgroupSize execution mode (see emit_module)
      raise Refused, "#{name}: sub-group shuffles need the OpenCL module (--kernel-cl)" unless @mod.kernel_cl
      @mod.subgroup_used = true
      @spv.cap(5568)   # SubgroupShuffleINTEL
      @spv.ext("SPV_INTEL_subgroups")
      v = u32_of(operand(args[0])[0], ["int", 4, false, false])
      m = u32_of(operand(args[1])[0], ["int", 4, false, false])
      op = name.end_with?("_xor_u32") ? 5574 : 5571   # OpSubgroupShuffleXorINTEL, OpSubgroupShuffleINTEL
      return [res(op, @spv.t_int(32), v, m), ["int", 4, false, false]]
    when "__nfcxx_sycl_barrier"
      ins([224, @spv.c_u32(SCOPE_WORKGROUP), @spv.c_u32(SCOPE_WORKGROUP), @spv.c_u32(@mod.kernel_cl ? SEM_BARRIER_KERNEL : SEM_BARRIER)])
      return nil
    when "__nfcxx_sycl_sg_barrier"
      # group_barrier(sub_group): in the OpenCL module a Subgroup-scope control barrier, as icpx emits it, so a sub-group
      # that reaches it alone does not wait for the rest of the work-group. The Vulkan module keeps the work-group barrier.
      if @mod.kernel_cl
        ins([224, @spv.c_u32(SCOPE_SUBGROUP), @spv.c_u32(SCOPE_SUBGROUP), @spv.c_u32(SEM_SG_BARRIER_KERNEL)])
      else
        ins([224, @spv.c_u32(SCOPE_WORKGROUP), @spv.c_u32(SCOPE_WORKGROUP), @spv.c_u32(SEM_BARRIER)])
      end
      return nil
    when "__nfcxx_sycl_fence"
      # atomic_fence(order, scope) as OpMemoryBarrier (OpenCL's atomic_work_item_fence with a memory scope). The function is
      # emitted once for all callers, so order and scope are run-time values here (no constant folding across the call):
      # memory_order relaxed/acquire/release/acq_rel/seq_cst = 0..4, memory_scope work_item/sub_group/work_group/device/system
      # = 0..4. The SPIR-V scope is 4 - scope (Invocation, Subgroup, Workgroup, Device, CrossDevice); the semantics are
      # 1 << order (Acquire, Release, AcquireRelease, SequentiallyConsistent) for order >= 1 and none for relaxed, with the
      # workgroup and cross-workgroup memory bits.
      o32 = ["int", 4, false, false]
      order = u32_of(operand(args[0])[0], o32)
      scope = u32_of(operand(args[1])[0], o32)
      spv_scope = res(130, @spv.t_int(32), @spv.c_u32(4), scope)   # ISub
      sh = res(196, @spv.t_int(32), @spv.c_u32(1), order)          # ShiftLeftLogical
      is_relaxed = res(170, @spv.t_bool, order, @spv.c_u32(0))     # IEqual
      ord_bits = res(169, @spv.t_int(32), is_relaxed, @spv.c_u32(0), sh)   # Select
      sem = res(197, @spv.t_int(32), ord_bits, @spv.c_u32(0x100 | 0x200))  # BitwiseOr with WorkgroupMemory | CrossWorkgroupMemory
      ins([225, spv_scope, sem])   # OpMemoryBarrier
      return nil
    when "__nfcxx_sycl_fn1", "__nfcxx_sycl_fn1_f64", "__nfcxx_sycl_fn2", "__nfcxx_sycl_fn3"
      op = args[0]
      raise Refused, "#{name} with a non-constant operation" unless head_of(op) == "const"
      k = as_int(op[2])
      ops = args.drop(1).map { |a| operand(a) }
      xs = ops.map { |o| o[0] }
      fty = ops[0][1]
      raise Refused, "#{name} on a #{fty[0]}" unless fty[0] == "float"
      ft = sty(fty)
      g = GLSL_OF_MATH[k]
      if k == 37
        return [copysign_bits(xs[0], xs[1], fty), fty]
      end
      if g.nil? && k == 36
        # fmod: x - y * trunc(x / y)
        q = res(136, ft, xs[0], xs[1])
        t = res(12, ft, @spv.glsl_id, @spv.ext_num(3), q)
        return [res(131, ft, xs[0], res(133, ft, xs[1], t)), fty]
      end
      raise Refused, "#{name} operation #{k}" if g.nil?
      return [glsl_op(g, xs, ft), fty]
    when "abs", "labs", "llabs"
      a, aty = operand(args[0])
      neg = res(ISUB, sty(aty), zero_of(aty), a)
      lt = res(177, @spv.t_bool, a, zero_of(aty))
      return [res(169, sty(aty), lt, neg, a), aty]
    when "__nfcxx_sycl_atomic_load"
      p = atomic_ptr(args[0])
      return [res(227, @spv.t_int(32), p, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED)), ["int", 4, false, false]]
    when "__nfcxx_sycl_atomic_cas"
      p = atomic_ptr(args[0])
      e = u32_of(operand(args[1])[0], ["int", 4, false, false])
      d = u32_of(operand(args[2])[0], ["int", 4, false, false])
      return [res_cas_value(p, e, d), ["int", 4, false, false]]
    when "__nfcxx_sycl_atomic_fadd", "__nfcxx_sycl_atomic_fmin", "__nfcxx_sycl_atomic_fmax"
      p_addr, _ = operand(args[0])
      v, _ = operand(args[1])
      float_atomic(p_addr, ["float", 4], v, { "fadd" => :add, "fmin" => :min, "fmax" => :max }[name.split("_").last])
      return [@spv.c_float(32, 0.0), ["float", 4]]
    when "__nfcxx_sycl_atomic_add", "__nfcxx_sycl_atomic_max", "__nfcxx_sycl_atomic_min", "__nfcxx_sycl_atomic_umax",
         "__nfcxx_sycl_atomic_umin", "__nfcxx_sycl_atomic_and", "__nfcxx_sycl_atomic_or", "__nfcxx_sycl_atomic_xor",
         "__nfcxx_sycl_atomic_xchg"
      kind = name[20..-1]
      code = { "add" => 234, "max" => 238, "min" => 236, "umax" => 239, "umin" => 237, "and" => 240, "or" => 241,
               "xor" => 242, "xchg" => 229 }[kind]
      p = atomic_ptr(args[0])
      v = u32_of(operand(args[1])[0], ["int", 4, false, false])
      return [res(code, @spv.t_int(32), p, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED), v), ["int", 4, false, false]]
    end
    if name == "copysignf" || name == "__builtin_copysignf"
      xs = args.map { |a| operand(a)[0] }
      return [copysign_bits(xs[0], xs[1], ["float", 4]), ["float", 4]]
    end
    if name == "copysign" || name == "__builtin_copysign"
      xs = args.map { |a| operand(a)[0] }
      return [copysign_bits(xs[0], xs[1], ["float", 8]), ["float", 8]]
    end
    if name == "fmodf" || name == "__builtin_fmodf"
      xs = args.map { |a| operand(a)[0] }
      ft = @spv.t_float(32)
      q = res(136, ft, xs[0], xs[1])
      t = res(12, ft, @spv.glsl_id, @spv.ext_num(3), q)
      return [res(131, ft, xs[0], res(133, ft, xs[1], t)), ["float", 4]]
    end
    if %w[memcpy memmove __builtin_memcpy __builtin_memmove].include?(name) && args.length == 3 && head_of(args[2]) == "const"
      d, _ = operand(args[0])
      sv, _ = operand(args[1])
      copy_bytes(d, sv, as_int(args[2][2]))
      return [d, ["ptr"]]
    end
    if %w[memset __builtin_memset].include?(name) && args.length == 3 && head_of(args[1]) == "const" && head_of(args[2]) == "const"
      d, _ = operand(args[0])
      byte = as_int(args[1][2]) & 255
      n = as_int(args[2][2])
      counted_loop(n, 1) do |off|
        mem_store(res(IADD, @spv.t_int(64), d, off), ["int", 1, false, false], @spv.c_u32(byte))
      end
      return [d, ["ptr"]]
    end
    if LIBM_GLSL.key?(name)
      xs = args.map { |a| operand(a)[0] }
      return [glsl_op(LIBM_GLSL[name], xs, @spv.t_float(32)), ["float", 4]]
    end
    if name.start_with?("__nfcxx_")
      raise Refused, "unknown device intrinsic #{name}"
    end
    # libstdc++'s assertion failure is noreturn (the host aborts): the device traps, as for an unreachable path
    if name == GLIBCXX_ASSERT_FAIL
      trap(5)
      check_dead_after_call
      return nil
    end
    callee_fn = @wgs_mode ? @mod.fns_wgs[name] : @mod.fns[name]
    raise Refused, "call of #{name}, which has no body in the device unit (a host function, or a declaration)" if callee_fn.nil?
    raise Refused, "call of #{name} with #{args.length} arguments, it takes #{callee_fn.ptypes.length}" if args.length != callee_fn.ptypes.length
    xs = args.map { |a| operand(a)[0] }
    xs += [state(:push), state(:sp), state(:dead)] if @mod.kernel_cl
    rt = callee_fn.ret ? sty(callee_fn.ret) : @spv.t_void
    if callee_fn.ret.nil?
      ins([57, rt, @spv.id, callee_fn.fid, *xs])
      check_dead_after_call
      return nil
    end
    r = res(57, rt, callee_fn.fid, *xs)
    check_dead_after_call
    [r, callee_fn.ret]
  end

  def atomic_ptr(x)
    raise Refused, "an atomic on memory in #{@name}, which may be a work-group static (not routed)" if @wgs_mode
    a, _ = operand(x)
    res(120, @spv.t_ptr(psb_sc, @spv.t_int(32)), a)
  end

  def res_cas_value(p, e, d)
    res(230, @spv.t_int(32), p, @spv.c_u32(SCOPE_DEVICE), @spv.c_u32(SEM_RELAXED), @spv.c_u32(SEM_RELAXED), d, e)
  end

  # copysign(x, y): |x| with the sign bit of y (the bit patterns of f32 and f64)
  def copysign_bits(x, y, fty)
    if fty[1] == 4
      ut, mag, sign = @spv.t_int(32), 0x7fffffff, 0x80000000
      xb = res(124, ut, x)
      yb = res(124, ut, y)
      r = res(199, ut, xb, @spv.c_u32(mag))
      sg = res(199, ut, yb, @spv.c_u32(sign))
      res(124, @spv.t_float(32), res(197, ut, r, sg))
    else
      ut = @spv.t_int(64)
      xb = res(124, ut, x)
      yb = res(124, ut, y)
      r = res(199, ut, xb, @spv.c_u64(0x7fffffffffffffff))
      sg = res(199, ut, yb, @spv.c_u64(0x8000000000000000))
      res(124, @spv.t_float(64), res(197, ut, r, sg))
    end
  end

  def glsl_op(g, xs, ft)
    i = @spv.id
    ins([12, ft, i, @spv.glsl_id, @spv.ext_num(g), *xs])
    i
  end

  def local_base
    lx = push_load(:nx, nil)
    ly = push_load(:ny, nil)
    wx = group_comp(0)
    wy = group_comp(1)
    wz = group_comp(2)
    t32 = @spv.t_int(32)
    lin = res(IADD, t32, res(IMUL, t32, res(IADD, t32, res(IMUL, t32, wz, ly), wy), lx), wx)
    stride = push_load(:local_stride, nil)
    off = res(IMUL, @spv.t_int(64), to_u64(lin, ["int", 4, false, false]), to_u64(stride, ["int", 4, false, false]))
    res(IADD, @spv.t_int(64), push_load(:local, nil), off)
  end

  # ---- statements

  def stmts(list)
    list.each_with_index do |s, i|
      nxt = list[i + 1]
      @pending_brk = ((head_of(s) == "loop" || head_of(s) == "switch") && head_of(nxt) == "label") ? nxt[1].to_s : nil
      stmt(s)
    end
  end

  def tail_label(list)
    last = list.last
    case head_of(last)
    when "label" then last[1].to_s
    when "block" then tail_label(last.drop(1))
    else nil
    end
  end

  def stmt(s)
    raise BadIR, "statement is not a form: #{form_text(s)}" unless s.is_a?(Array)
    h = head_of(s)
    case h
    when "block"
      stmts(s.drop(1))
    when "let"
      ty = parse_type(s[2])
      v, vty = rval(s[3], ty)
      r = @regs[s[1]]
      if r.nil?
        vv = var_decl(sty(ty))
        r = [:var, vv, ty]
        @regs[s[1]] = r
      end
      ins([62, r[1], v])
    when "set"
      r = @regs[s[1]]
      raise BadIR, "set of #{s[1]} before its let" if r.nil?
      v, _ = operand(s[2])
      ins([62, r[1], v])
    when "store", "store.v"
      ty = parse_type(s[1])
      v, _ = operand(s[3])
      if s[2].is_a?(IRSym) && s[2].sig == "$" && @locals.key?(s[2].name)
        lv = @locals[s[2].name]
        lv[0] ||= var_decl(sty(lv[1]))
        ins([62, lv[0], v])
      else
        a, _ = operand(s[2])
        mem_store(a, ty, v)
      end
    when "if"
      c, cty = operand(s[1])
      raise BadIR, "if condition is not a bool" unless cty[0] == "int" && cty[3]
      then_f = s.drop(2).find { |f| head_of(f) == "then" }
      else_f = s.drop(2).find { |f| head_of(f) == "else" }
      raise BadIR, "if without then" if then_f.nil?
      t = new_label
      e = new_label
      m = new_label
      ins([247, m, 0])
      cond_branch(c, t, e)
      label(t)
      stmts(then_f.drop(1))
      branch(m)
      label(e)
      stmts(else_f.drop(1)) if else_f
      branch(m)
      label(m)
    when "loop"
      body_f = s.drop(1).find { |f| head_of(f) == "body" }
      step_f = s.drop(1).find { |f| head_of(f) == "step" }
      raise BadIR, "loop without body and step" if body_f.nil? || step_f.nil?
      hdr = new_label
      body = new_label
      cont = new_label
      merge = new_label
      brk = @pending_brk
      @pending_brk = nil
      @labels[brk] = [merge, :brk] if brk
      end_label = tail_label(body_f.drop(1))
      @labels[end_label] = [cont, :cont] if end_label
      # for (init; c; step) body, as the IR has it: the step runs at the top of every iteration but the first, before the
      # condition (which starts the body). A continue then goes to an empty block that returns to the header, so the
      # continue construct has no checks in it (SPIR-V's structure rules for it are strict).
      first = var_decl(@spv.t_int(32))
      ins([62, first, @spv.c_u32(1)])
      branch(hdr)
      label(hdr)
      ins([246, merge, cont, 0])
      branch(body)
      @loops.push({ brk: merge, cont: cont })
      label(body)
      f = res(61, @spv.t_int(32), first)
      nf = res(170, @spv.t_bool, f, @spv.c_u32(0))   # the step runs unless this is the first iteration
      run = new_label
      after = new_label
      ins([247, after, 0])
      cond_branch(nf, run, after)
      label(run)
      stmts(step_f.drop(1)) if step_f.length > 1
      branch(after)
      label(after)
      ins([62, first, @spv.c_u32(0)])
      stmts(body_f.drop(1))
      @loops.pop
      branch(cont)
      label(cont)
      branch(hdr)
      label(merge)
    when "switch"
      switch_stmt(s)
    when "break"
      raise Refused, "break outside a loop or switch" if @loops.empty?
      branch(@loops[-1][:brk])
    when "continue"
      enc = @loops.reverse.find { |e| e[:cont] }
      raise BadIR, "continue outside a loop" if enc.nil?
      branch(enc[:cont])
    when "goto"
      ent = @labels[s[1].to_s]
      raise Refused, "goto \"#{s[1]}\" (not the end of a loop body or the label after a loop or switch)" if ent.nil?
      branch(ent[0])
    when "label"
      nil
    when "trap", "unreachable"
      trap(5)
    when "bounds"
      v, vty = operand(s[1])
      n = s[2].is_a?(String) && s[2].start_with?("%") ? operand(s[2])[0] : int_const_of(vty, as_int(s[2]))
      vi = wide?(vty) ? v : u32_of(v, vty)
      trap_if(res(172, @spv.t_bool, vi, n), 3)
    when "nonnull"
      # the address of a function is never null (the front end's check on a function pointer that is a template argument)
      unless s[1].is_a?(IRSym) && s[1].sig == "&"
        p, _ = operand(s[1])
        trap_if(res(170, @spv.t_bool, p, @spv.c_u64(0)), 4)
      end
    when "return"
      if @ret.nil?
        raise Refused, "return with a value in a void function" if s.length > 1
        emit_return(nil)
      else
        raise Refused, "return without a value in #{@name}" unless s.length == 2
        v, _ = operand(s[1])
        emit_return(v)
      end
    when "eval"
      raise Refused, "eval of #{form_text(s[1])}" unless s.length == 2 && head_of(s[1]) == "call"
      call_expr(s[1])
    when "copy"
      n = as_int(s[1])
      d, _ = operand(s[2])
      src, _ = operand(s[3])
      copy_bytes(d, src, n)
    else
      raise Refused, "statement #{h || form_text(s)}"
    end
  end

  # a counted loop over the byte offsets of an n-byte block: body(offset) for each step of `step` bytes
  def counted_loop(n, step)
    i = var_decl(@spv.t_int(64))
    ins([62, i, @spv.c_u64(0)])
    hdr = new_label
    body = new_label
    cont = new_label
    merge = new_label
    branch(hdr)
    label(hdr)
    iv = res(61, @spv.t_int(64), i)
    c = res(176, @spv.t_bool, iv, @spv.c_u64(n))
    ins([246, merge, cont, 0])
    cond_branch(c, body, merge)
    label(body)
    yield iv
    branch(cont)
    label(cont)
    iv2 = res(61, @spv.t_int(64), i)
    nx = res(IADD, @spv.t_int(64), iv2, @spv.c_u64(step))
    ins([62, i, nx])
    branch(hdr)
    label(merge)
  end

  def copy_bytes(d, src, n)
    if n % 4 == 0
      counted_loop(n, 4) do |off|
        v = mem_load(res(IADD, @spv.t_int(64), src, off), ["int", 4, false, false])
        mem_store(res(IADD, @spv.t_int(64), d, off), ["int", 4, false, false], v)
      end
    else
      counted_loop(n, 1) do |off|
        v = mem_load(res(IADD, @spv.t_int(64), src, off), ["int", 1, false, false])
        mem_store(res(IADD, @spv.t_int(64), d, off), ["int", 1, false, false], v)
      end
    end
  end

  def switch_stmt(s)
    brk = @pending_brk
    @pending_brk = nil
    body_f = s.drop(1).find { |f| head_of(f) == "body" }
    raise BadIR, "switch without body" if body_f.nil?
    v, vty = operand(s[1])
    raise Refused, "switch on a #{vty[0]}" unless int_ty?(vty)
    raise Refused, "switch on a #{vty[1]}-byte integer" unless vty[1] <= 4
    items = []
    expand = lambda { |f| head_of(f) == "block" ? f.drop(1).each { |t| expand.call(t) } : items << f }
    body_f.drop(1).each { |f| expand.call(f) }
    arms = []   # [labels, stmts, block id]
    cur = nil
    items.each do |it|
      h = head_of(it)
      if h == "case" || h == "default"
        if cur.nil? || !cur[1].empty?
          cur = [[], [], new_label]
          arms << cur
        end
        cur[0] << (h == "case" ? as_int(it[1][2]) : :default)
      else
        raise Refused, "statement before the first case of a switch" if cur.nil?
        cur[1] << it
      end
    end
    arms.each_with_index do |arm, i|
      next if i == arms.length - 1 || arm[1].empty?
      raise Refused, "switch arm falls through into the next one" unless jump?(arm[1][-1])
    end
    merge = new_label
    dflt = arms.find { |a| a[0].include?(:default) }
    dflt_label = dflt ? dflt[2] : merge
    pairs = []
    arms.each { |a| a[0].each { |l| pairs << [l, a[2]] unless l == :default } }
    ins([247, merge, 0])
    flat = []
    pairs.each { |lit, lab| flat << (lit & 0xffffffff) << lab }
    term([251, u32_of(v, vty), dflt_label, *flat])
    @loops.push({ brk: merge, cont: nil })
    @labels[brk] = [merge, :brk] if brk
    arms.each_with_index do |arm, i|
      label(arm[2])
      stmts(arm[1])
      nxt = i + 1 < arms.length ? arms[i + 1][2] : merge
      branch(nxt)
    end
    @loops.pop
    label(merge)
  end

  def jump?(s)
    h = head_of(s)
    return true if h == "break" || h == "continue" || h == "return" || h == "unreachable" || h == "trap" || h == "goto"
    if h == "block"
      return s.length > 1 && jump?(s[-1])
    end
    if h == "if"
      t = s.drop(2).find { |f| head_of(f) == "then" }
      e = s.drop(2).find { |f| head_of(f) == "else" }
      return t && e && t.length > 1 && e.length > 1 && jump?(t[-1]) && jump?(e[-1])
    end
    false
  end

  # ---- the function

  def compile
    ret_t = @ret ? sty(@ret) : @spv.t_void
    @ptypes.each { |t| @param_ids << @spv.id }
    @ptypes.each_with_index { |t, k| @regs["%#{k}"] = [:val, @param_ids[k], t] }
    state_types = []
    if @mod.kernel_cl
      state_types = [@spv.t_ptr(SC_CROSSWG, @mod.push_struct_type), @spv.t_ptr(SC_FUNCTION, @spv.t_int(64)),
                     @spv.t_ptr(SC_FUNCTION, @spv.t_int(32))]
      @state_param_ids = state_types.map { @spv.id }
      @state = { push: @state_param_ids[0], sp: @state_param_ids[1], dead: @state_param_ids[2] }
    end
    @state_types = state_types
    @ftype = @spv.t_fn(ret_t, @ptypes.map { |t| sty(t) } + state_types)
    @ret_t = ret_t
    if @frame > 0
      @oldsp_var = var_decl(@spv.t_int(64))
      @frame_var = var_decl(@spv.t_int(64))
      old = res(61, @spv.t_int(64), state(:sp))
      ins([62, @oldsp_var, old])
      fr = res(IADD, @spv.t_int(64), old, @spv.c_u64(-@frame))
      fr = res(199, @spv.t_int(64), fr, @spv.c_u64(0xfffffffffffffff0))
      ins([62, @frame_var, fr])
      ins([62, state(:sp), fr])
    end
    @locals.each_value { |lv| lv[0] ||= var_decl(sty(lv[1])) }
    stmts(@body)
    if !@term
      if @ret.nil?
        emit_return(nil)
      else
        emit_return(zero_of(@ret))
      end
    end
    @code
  end

  def function_text
    out = []
    out << [54, @ret_t, @fid, 0, @ftype]
    @ptypes.each_with_index { |t, k| out << [55, sty(t), @param_ids[k]] }
    @state_types.each_with_index { |t, k| out << [55, t, @state_param_ids[k]] }
    lab = @spv.id
    out << [248, lab]
    @vars.each { |v| out << v }
    out.concat(@code)
    out << [56]
    out
  end
end

# ------------------------------------------------------------------ the module

class SpvModule
  attr_accessor :irmod
  def static_offset_of(name)
    @irmod.static_offset(name)
  end
end

def emit_module(src, kernel_cl = false)
  forms = parse_forms(tokenize(strip_comments(src)))
  mod = Mod.new
  sizes = {}
  forms.each do |f|
    h = head_of(f)
    if h == "function"
      mod.defs[f[1].to_s] = f
    elsif h == "abi-type"
      sizes[f[1].to_s] = as_int(f[2])
      mod.empty_types[f[1].to_s] = true if head_of(f[4]) == "empty"
    elsif h == "global"
      mod.globals[f[1].to_s] = f
    elsif h == "data"
      mod.datas[f[1].to_s] = f
    end
  end
  entries = mod.defs.keys.select { |n| n.include?("__nfcxx_sycl_entry_") }
  return [nil, [], nil] if entries.empty?
  # the array constructor calls of a reachable function are unrolled before its callees are taken (see visit)
  order = []
  state = {}
  visit = lambda do |name|
    next if state[name] == :done
    raise Refused, "recursive call of #{name}" if state[name] == :open
    state[name] = :open
    expand_cxa_vec_ctor(mod.defs[name]) if mod.defs[name].is_a?(Array)
    callees = collect_calls(mod.defs[name], []).select { |c| mod.defs.key?(c) }.uniq
    callees.each { |c| visit.call(c) }
    state[name] = :done
    order << name
  end
  entries.each { |e| visit.call(e) }

  spv = Spv.new
  spv.kernel_cl = kernel_cl
  if kernel_cl
    spv.cap(4)    # Addresses (the pointers are CrossWorkgroup, made from the 64-bit addresses)
    spv.cap(6)    # Kernel
    spv.cap(11)   # Int64
  else
    spv.cap(1)
    spv.cap(11)     # Int64
    spv.cap(5347)   # PhysicalStorageBufferAddresses
    spv.cap(5345)   # VulkanMemoryModel
    spv.cap(5346)   # VulkanMemoryModelDeviceScope (device-scope atomics)
    spv.ext("SPV_KHR_physical_storage_buffer")
  end
  spv.glsl_id
  smod = SpvModule.new(spv, kernel_cl)
  smod.irmod = mod
  smod.defs = mod.defs
  # the work-group statics live in the group's static local region (OpenCL-style modules; the Vulkan module keeps frames)
  if kernel_cl
    smod.wgs, smod.wgs_total = wgs_layout(mod.defs)
    # the static storage: a Workgroup variable (OpenCL local memory) of the group's static bytes, when there are statics
    smod.wgs_var = spv.wgs_var(smod.wgs_total / 4) if smod.wgs_total > 0
  end
  fns = {}
  order.each_with_index do |n, i|
    fn = SFn.new(mod.defs[n], spv.id, smod)
    fns[n] = fn
  end
  smod.fns = fns
  # Clones for the work-group-static kernels. A kernel whose call graph reaches a function with a work-group static gets a
  # clone (wgs_mode) of every function it reaches: the clone routes its memory accesses to the group's static storage, the
  # original keeps the global path. Non-static kernels reach only originals, so their code is unchanged. The clones are
  # created after the originals, so the originals' ids do not move; each clone compiles from its own copy of the IR.
  static_names = smod.wgs ? smod.wgs.keys.map { |k| k[0] }.uniq : []
  reach = lambda do |root|
    seen = {}
    stack = [root]
    until stack.empty?
      n = stack.pop
      next if seen[n] || !mod.defs.key?(n)
      seen[n] = true
      stack.concat(collect_calls(mod.defs[n], []).select { |c| mod.defs.key?(c) })
    end
    seen.keys
  end
  static_entries = entries.select { |e| reach.call(e).any? { |n| static_names.include?(n) } }
  clone_set = static_entries.flat_map { |e| reach.call(e) }.uniq
  clone_order = order.select { |n| clone_set.include?(n) }
  # a copy of the forms: the arrays are copied, the tokens (IRStr, IRSym, strings, numbers) are shared, as they are immutable
  copy_forms = lambda { |x| x.is_a?(Array) ? x.map { |y| copy_forms.call(y) } : x }
  clone_order.each do |n|
    smod.fns_wgs[n] = SFn.new(copy_forms.call(mod.defs[n]), spv.id, smod, true)
  end
  # the stack: the deepest chain of frames from a kernel, with slack for alignment
  depth = {}
  depth_of = nil
  depth_of = lambda do |name|
    return depth[name] if depth.key?(name)
    fn = fns[name]
    d = fn.frame + (fn.callees.map { |c| depth_of.call(c) }.max || 0)
    depth[name] = d
  end
  stack_bytes = entries.map { |e| depth_of.call(e) }.max.to_i + 16
  stack_bytes = (stack_bytes + 15) / 16 * 16
  smod.stack_bytes = stack_bytes
  # the originals that a non-static entry reaches (the ids of all originals are fixed above; an original that only a
  # static-using kernel reaches is not compiled, its clone is)
  orig_needed = {}
  entries.each { |e| reach.call(e).each { |n| orig_needed[n] = true } unless static_entries.include?(e) }
  order.each { |n| fns[n].compile if orig_needed[n] }
  clone_order.each { |n| smod.fns_wgs[n].compile }
  order.each do |n|
    next unless orig_needed[n]
    fn = fns[n]
    fn.function_text.each { |inst| spv.func(inst) }
  end
  clone_order.each do |n|
    smod.fns_wgs[n].function_text.each { |inst| spv.func(inst) }
  end
  iface = kernel_cl ? [smod.gid, smod.lid, smod.wid] : [smod.gid, smod.lid, smod.wid, smod.sp, smod.dead, smod.push]
  manifest = []
  entries.each_with_index do |e, k|
    f = smod.fns_wgs.key?(e) ? smod.fns_wgs[e] : fns[e]
    raise Refused, "kernel #{e} takes parameters" unless f.ptypes.empty?
    key, struct = kernel_key(mod.defs[e])
    raise Refused, "kernel #{e}: cannot find the closure type (no cast of __nfcxx_sycl_closure())" if key.nil?
    wr = SFn.new(nil, spv.id, smod).compile_wrapper(f.fid)
    spv.func([54, spv.t_void, wr.fid, 0, wr.ftype])
    wr.param_lines.each { |inst| spv.func(inst) }
    spv.func([248, spv.id])
    wr.vars.each { |inst| spv.func(inst) }
    wr.code.each { |inst| spv.func(inst) }
    spv.func([56])
    spv.add_entry(kernel_cl ? 6 : 5, wr.fid, "k#{k}", iface, smod.spec_ids)
    if smod.subgroup_used
      # the sub-group size is fixed at 16 (the Intel default that ggml uses); the host picks work-group sizes that are multiples of it
      spv.cap(58)                        # SubgroupDispatch: the SubgroupSize execution mode needs it
      spv.entry_mode(wr.fid, 35, SUBGROUP_SIZE)
    end
    manifest << "k#{k}\t#{key}\t#{sizes[struct] || 0}"
  end
  manifest << "G\t#{SUBGROUP_SIZE}" if smod.subgroup_used   # the sub-group size the runtimes check (rt_opencl.hpp, rt_level_zero.hpp)
  static_bytes = 0
  if mod.statics.size > 0 || !mod.static_order.empty?
    bytes, relocs = mod.static_image
    manifest << "S\t#{mod.static_size}\t#{bytes.map { |b| ('0' + b.to_s(16))[-2, 2] }.join}"
    relocs.each { |o, t| manifest << "R\t#{o}\t#{t}" }
  end
  manifest << "L\t#{smod.wgs_total}" if smod.wgs_total > 0   # the work-group static bytes per group (see wgs_layout)
  manifest << "T\t#{stack_bytes}"
  [spv.finish(kernel_cl ? 0x00010200 : 0x00010500), manifest, nil]   # OpenCL 2.2 takes SPIR-V 1.2
end

def main(argv)
  args = argv.dup
  manifest_path = nil
  kernel_cl = false
  while args.length > 0 && args[0].start_with?("--")
    opt = args.shift
    if opt.start_with?("--manifest=")
      manifest_path = opt[11..-1]
    elsif opt == "--kernel-cl"
      kernel_cl = true
    else
      $stderr.write("usage: pathb-spirv-emit.rb [--kernel-cl] [--manifest=FILE] [FILE.ir | -] > out.spv\n")
      return 1
    end
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    words, manifest, _ = emit_module(src, kernel_cl)
  rescue Refused => e
    $stderr.write("refused: #{e.message}\n")
    return 3
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  if words
    $stdout.write(words.pack("V*"))
  end
  File.open(manifest_path, "wb") { |f| f.write(manifest.join("\n") + "\n") } if manifest_path
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
