# CUDA launch rewrite for nfcxx: turns the kernel launch syntax of a .cu file into a call of
# __nfcxx_cuda_launch (lib/cuda/nfcxx_cuda.h), so the EDG front end sees only C++.
#   name<<<grid, block[, shmem[, stream]]>>>(args)  ->  __nfcxx_cuda_launch(name, grid, block, shmem, stream, args)
# Usage: scripts/mrb scripts/cuda-rewrite.rb FILE.cu > FILE.cpp
#
# A small scanner, not a parser: string, character and raw string literals and comments are copied as they are, so
# `<<<` inside them is not a launch. Newlines inside a launch are kept (as the same number after the call), so line
# numbers after it do not move. The output starts with `#line 1 "FILE.cu"`, so diagnostics name the original file.
# Forms not handled exit 3 with `refused: ...` on stderr: a template kernel name (`k<float><<<...>>>`), a launch
# without a kernel name, and a configuration with fewer than 2 or more than 4 items.
# No regexp: scripts run on mruby, which has none in core.

# The character before position i, skipping whitespace; "" at the start.
def text_before(text, i)
  j = i - 1
  j -= 1 while j >= 0 && white?(text[j])
  j < 0 ? "" : text[j]
end

def white?(c)
  c == " " || c == "\t" || c == "\n" || c == "\r"
end

def ident_char?(c)
  return false if c.nil?
  o = c.ord
  (o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || o == 95
end

def refuse(msg)
  $stderr.puts "refused: #{msg}"
  exit(3)
end

# If a literal or comment starts at s[i], returns the index just past it; otherwise nil.
def skip_literal(s, i)
  n = s.length
  c = s[i]
  if c == "/" && s[i + 1] == "/"
    j = s.index("\n", i)
    return j.nil? ? n : j
  end
  if c == "/" && s[i + 1] == "*"
    j = s.index("*/", i + 2)
    refuse("unterminated comment") if j.nil?
    return j + 2
  end
  if c == "R" && s[i + 1] == "\"" && !(i > 0 && ident_char?(s[i - 1]))
    paren = s.index("(", i + 2)
    refuse("raw string delimiter") if paren.nil?
    delim = s[(i + 2)...paren]
    close = s.index(")" + delim + "\"", paren + 1)
    refuse("unterminated raw string") if close.nil?
    return close + delim.length + 2
  end
  # A quote after a digit is a digit separator (1'000), not a character literal.
  return nil if c == "'" && i > 0 && s[i - 1].ord >= 48 && s[i - 1].ord <= 57
  if c == "\"" || c == "'"
    j = i + 1
    while j < n
      if s[j] == "\\"
        j += 2
      elsif s[j] == c
        return j + 1
      else
        j += 1
      end
    end
    refuse("unterminated literal")
  end
  nil
end

# Index of the bracket that closes the one at s[open] (which is `(`), skipping literals; nil if none.
def matching_paren(s, open)
  depth = 0
  i = open
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "(" || c == "[" || c == "{"
      depth += 1
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1
      return i if depth == 0
    end
    i += 1
  end
  nil
end

# Splits the launch configuration text at its top-level commas.
def split_config(s, from, to)
  items = []
  depth = 0
  start = from
  i = from
  while i < to
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "(" || c == "[" || c == "{"
      depth += 1
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1
    elsif c == "," && depth == 0
      items << s[start...i].strip
      start = i + 1
    end
    i += 1
  end
  items << s[start...to].strip
  items
end

# Template kernel launches: `k<T...><<<...>>>(args)` is a call of a generated C-linkage wrapper (see
# template_sites), so the host registration and the device image name the same entry.
$expanded = ""   # the source with local quoted includes expanded, for the template definitions
$sites = {}      # wrapper name => { name:, targs:, decl:, call: }

def split_top(s)
  parts = []
  depth = 0
  start = 0
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "(" || c == "[" || c == "{" || c == "<"
      depth += 1
    elsif c == ")" || c == "]" || c == "}" || c == ">"
      depth -= 1
    elsif c == "," && depth == 0
      parts << s[start...i].strip
      start = i + 1
    end
    i += 1
  end
  parts << s[start...s.length].strip
  parts.reject { |x| x.empty? }
end

def sanitize(s)
  out = ""
  s.each_char do |c|
    out << (ident_char?(c) ? c : "_")
  end
  out.gsub("__", "_")
end

def wrapper_name(name, targs)
  "__nfcxx_k_#{sanitize(name)}_#{sanitize(targs)}"
end

# Index of the first character c at or after from, outside comments and literals; nil if none.
def index_code(s, c, from)
  i = from
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    return i if s[i] == c
    i += 1
  end
  nil
end

# The template header of the first __global__ template named `name` in the source: its parameter names, and its
# parameter list text.
def kernel_template(name)
  top_pieces($expanded).each do |st, en, kind, body|
    next unless kind == :code && body
    t = $expanded[st...en]
    toks = tokens_of(t)
    next unless toks.first == "template" && toks.include?("__global__")
    q = remove_words(t, DEVICE_QUALIFIERS)
    next unless function_name(q) == name
    lt = index_code(q, "<", 0)
    depth = 0
    k = lt
    while k < q.length
      depth += 1 if q[k] == "<"
      depth -= 1 if q[k] == ">"
      break if depth == 0
      k += 1
    end
    names = split_top(q[(lt + 1)...k]).map { |part| tokens_of(part.split("=")[0]).last }.compact
    open = index_code(q, "(", k)
    close = matching_paren(q, open)
    refuse("unterminated parameter list for #{name}") if close.nil?
    return { names: names, params: q[(open + 1)...close] }
  end
  nil
end

# Replaces the template parameter names in the parameter list by the explicit arguments.
def substitute(text, names, args)
  map = {}
  names.each_with_index { |n, idx| map[n] = args[idx] }
  out = ""
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if ident_char?(text[i]) && !(text[i] >= "0" && text[i] <= "9")
      j = i
      j += 1 while j < text.length && ident_char?(text[j])
      w = text[i...j]
      out << (map[w] || w)
      i = j
    else
      out << text[i]
      i += 1
    end
  end
  out
end

# The wrapper of a template launch: its declaration (the instance's parameters with the arguments substituted) and
# the names the call passes. Registers it in $sites.
def template_site(name, targs)
  kt = kernel_template(name)
  refuse("template kernel #{name}: no __global__ template of that name in the source") if kt.nil?
  args = split_top(targs)
  if args.length != kt[:names].length
    refuse("template kernel #{name}<#{targs}>: explicit arguments must give every template parameter")
  end
  decl = substitute(kt[:params], kt[:names], args)
  call = split_top(decl).map do |part|
    n = tokens_of(part.split("=")[0]).last
    refuse("template kernel #{name}: unnamed parameter #{part}") if n.nil?
    n
  end
  w = wrapper_name(name, targs)
  $sites[w] = { name: name, targs: targs, decl: decl, call: call } unless $sites.key?(w)
  w
end

# The template launches of a source: [name, targs] for each `<<<` that follows a template argument list.
# The nearest `template <...>` header before position i (the function or class the launch is in): if the template
# arguments of a launch name one of its parameters, that parameter's name; else nil. A launch like that needs an
# instance that only the instantiation fixes, and the wrapper is a concrete function (see template_site).
def dependent_on_template(text, i, targs)
  j = i - 1
  while j >= 0
    if word_at?(text, j, "template")
      k = j + 8
      k += 1 while k < text.length && white?(text[k])
      if text[k] == "<"
        close = matching_angle(text, k)
        if close && close < i
          params = split_top(text[(k + 1)...close])
          names = params.map { |pr| pr.split("=")[0] }.map { |pr| tokens_of(pr).last }.compact
          used = tokens_of(targs)
          hit = names.find { |nm| used.include?(nm) }
          return hit unless hit.nil?
          return nil
        end
      end
    end
    j -= 1
  end
  nil
end

# Index of the `>` closing the `<` at s[open] (nesting counted), or nil.
def matching_angle(s, open)
  depth = 0
  k = open
  while k < s.length
    e = skip_literal(s, k)
    if e
      k = e
      next
    end
    depth += 1 if s[k] == "<"
    if s[k] == ">"
      depth -= 1
      return k if depth == 0
    end
    k += 1
  end
  nil
end

def template_launches(text)
  found = []
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if text[i, 3] == "<<<" && text_before(text, i) == ">"
      j = i - 1
      depth = 0
      while j >= 0
        depth += 1 if text[j] == ">"
        depth -= 1 if text[j] == "<"
        break if depth == 0
        j -= 1
      end
      k = j - 1
      k -= 1 while k >= 0 && white?(text[k])
      e2 = k + 1
      k -= 1 while k >= 0 && ident_char?(text[k])
      name = text[(k + 1)...e2]
      found << [name, text[(j + 1)...(i - 1)].strip, i] unless name.empty?
    end
    i += 1
  end
  found
end

def rewrite(text, orig)
  out = "#line 1 \"#{orig}\"\n"
  n = text.length
  i = 0
  # The wrapper declarations of the template launches, at file scope just before the top-level piece that holds
  # each launch: EDG rejects a linkage specification in block scope. Keyed by the piece's start index.
  pieces = top_pieces(text)
  decls_at = Hash.new { |h, k| h[k] = [] }
  template_launches(text).each do |nm, ta, pos|
    next unless dependent_on_template(text, pos, ta).nil?
    w = template_site(nm, ta)
    piece = pieces.find { |st, en, _kind, _body| st <= pos && pos < en }
    decls_at[piece ? piece[0] : 0] << w unless decls_at[piece ? piece[0] : 0].include?(w)
  end
  while i < n
    if decls_at.key?(i)
      decls_at.delete(i).each { |w| out << "static void #{w}(#{$sites[w][:decl]});\n" }
    end
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if text[i, 3] == "<<<" && !(i + 3 < n && text[i + 3] == "<")
      line = text[0...i].count("\n") + 1
      # The kernel name is the identifier before `<<<`, or before its template argument list.
      j = i - 1
      j -= 1 while j >= 0 && white?(text[j])
      targs = nil
      if text[j] == ">"
        depth = 0
        while j >= 0
          depth += 1 if text[j] == ">"
          depth -= 1 if text[j] == "<"
          break if depth == 0
          j -= 1
        end
        targs = text[(j + 1)...(i - 1)].strip
        j -= 1
        j -= 1 while j >= 0 && white?(text[j])
      end
      name_end = j + 1
      name_start = name_end
      name_start -= 1 while name_start > 0 && ident_char?(text[name_start - 1])
      name = text[name_start...name_end]
      refuse("launch without a kernel name at line #{line}") if name.empty?
      # The call copied so far ends with the name and its arguments: take them back out.
      out = out[0...(out.length - (i - name_start))]

      # The configuration runs to the first `>>>` outside brackets.
      k = i + 3
      depth = 0
      close_cfg = nil
      while k < n
        e2 = skip_literal(text, k)
        if e2
          k = e2
          next
        end
        c = text[k]
        if c == "(" || c == "[" || c == "{"
          depth += 1
        elsif c == ")" || c == "]" || c == "}"
          depth -= 1
        elsif depth == 0 && text[k, 3] == ">>>"
          close_cfg = k
          break
        end
        k += 1
      end
      refuse("unterminated launch configuration for #{name}") if close_cfg.nil?
      cfg = split_config(text, i + 3, close_cfg)
      refuse("launch of #{name} needs 2 to 4 configuration items") if cfg.length < 2 || cfg.length > 4
      cfg += ["0"] * (4 - cfg.length)
      cfg[2] = "0" if cfg[2].empty?
      cfg[3] = "0" if cfg[3].empty?

      p = close_cfg + 3
      p += 1 while p < n && (text[p] == " " || text[p] == "\t" || text[p] == "\n" || text[p] == "\r")
      refuse("launch of #{name} without an argument list") if text[p] != "("
      close_args = matching_paren(text, p)
      refuse("unterminated argument list for #{name}") if close_args.nil?
      args = text[(p + 1)...close_args].strip

      lines = text[i..close_args].count("\n")
      kernel = name
      if targs
        dep = dependent_on_template(text, i, targs)
        refuse("template launch of #{name}<#{targs}> depends on the template parameter #{dep} of the enclosing template: " \
               "the device image would need that instance, which is not built yet (at line #{line})") unless dep.nil?
        kernel = template_site(name, targs)
      end
      out << "__nfcxx_cuda_launch(#{kernel}, #{cfg[0]}, #{cfg[1]}, #{cfg[2]}, #{cfg[3]}"
      out << ", #{args}" unless args.empty?
      out << ")"
      out << ("\n" * lines)
      i = close_args + 1
      next
    end
    out << text[i]
    i += 1
  end
  # The wrappers are defined here, after the calls; each call has the declaration in its block.
  unless $sites.empty?
    out << "\n"
    $sites.each do |w, site|
      out << "static void #{w}(#{site[:decl]}) {}\n"
    end
  end
  out
end

# ---- device side (--device): the __global__ and __device__ functions as a device-only translation unit

DEVICE_BUILTINS = {
  "threadIdx" => "tid", "blockIdx" => "ctaid", "blockDim" => "ntid", "gridDim" => "nctaid",
}
DEVICE_AXES = ["x", "y", "z"]
DEVICE_QUALIFIERS = ["__global__", "__device__", "__host__", "__forceinline__"]

def word_at?(s, i, w)
  s[i, w.length] == w && !(i > 0 && ident_char?(s[i - 1])) && !ident_char?(s[i + w.length])
end

# threadIdx.x and the others become calls of the intrinsics DEVICE_INTRINSICS (scripts/pathb-ptx-emit.rb) reads.
def rewrite_builtins(t)
  out = ""
  i = 0
  while i < t.length
    e = skip_literal(t, i)
    if e
      out << t[i...e]
      i = e
      next
    end
    # `extern __shared__ T x[];` is a shared-memory declaration: the prelude's static replaces both words
    if word_at?(t, i, "extern")
      j = i + 6
      j += 1 while t[j] == " " || t[j] == "\t" || t[j] == "\n"
      if word_at?(t, j, "__shared__")
        i = j
        next
      end
    end
    if word_at?(t, i, "__syncthreads") && t[i + 13] == "("
      out << "__nfcxx_syncthreads"
      i += 13
      next
    end
    # __syncwarp(mask) is the warp barrier of the mask; __syncwarp() is the full warp (CUDA's default mask)
    if word_at?(t, i, "__syncwarp") && t[i + 10] == "("
      out << "__nfcxx_syncwarp("
      j = i + 11
      j += 1 while j < t.length && white?(t[j])
      out << "0xffffffffu" if t[j] == ")"
      i += 11
      next
    end
    hit = false
    DEVICE_BUILTINS.each do |name, prefix|
      next if hit || !word_at?(t, i, name)
      j = i + name.length
      next unless t[j] == "." && DEVICE_AXES.include?(t[j + 1]) && !ident_char?(t[j + 2])
      out << "__nfcxx_#{prefix}_#{t[j + 1]}()"
      i = j + 2
      hit = true
    end
    next if hit
    out << t[i]
    i += 1
  end
  out
end

def device_decls
  decls = []
  DEVICE_BUILTINS.each_value do |prefix|
    DEVICE_AXES.each { |a| decls << "extern \"C\" unsigned __nfcxx_#{prefix}_#{a}(void);" }
  end
  decls.join("\n")
end

# The device unit's prelude: the CUDA names that the host headers would give (uint, NULL), the shared-memory
# qualifier (a static object here, which the emitter refuses until static data is lowered), and __syncthreads
# (an intrinsic the emitter does not lower yet, so a kernel that uses it is refused by name).
DEVICE_PRELUDE = <<'PRELUDE'
typedef unsigned int uint;
typedef unsigned short ushort;
typedef unsigned long ulong;
#ifndef NULL
#define NULL 0
#endif
#define __shared__ static
extern "C" void __nfcxx_syncthreads(void);
extern "C" void __nfcxx_syncwarp(unsigned int mask);
extern "C" void *__nfcxx_dynshared_addr(void);
PRELUDE

# CUDA's vector types (uchar4, uint2, float3, ...) come from the CUDA headers, which the device unit does not
# include. A vector type is defined here only when device code names it, so a unit that does not use one has no
# extra declaration. Each has its struct (members x, y, z, w) and its make_ constructor, as in vector_types.h.
VECTOR_BASES = [["char", "signed char"], ["uchar", "unsigned char"], ["short", "short"], ["ushort", "unsigned short"],
                ["int", "int"], ["uint", "unsigned int"], ["float", "float"]]
VECTOR_LANES = ["x", "y", "z", "w"]

def vector_defs
  defs = {}
  VECTOR_BASES.each do |base, ctype|
    [2, 3, 4].each do |n|
      name = "#{base}#{n}"
      members = VECTOR_LANES[0, n]
      params = members.map { |m| "#{ctype} #{m}" }.join(", ")
      init = members.join(", ")
      text = "struct #{name} { #{ctype} #{members.join(", ")}; };\n" \
             "static inline #{name} make_#{name}(#{params}) { #{name} r = {#{init}}; return r; }\n"
      defs[name] = text
      defs["make_#{name}"] = text
    end
  end
  defs
end

VECTOR_DEFS = vector_defs

# Device builtins that the CUDA headers define as functions, provided in the unit when device code names them
# (the same rule as the vector types). __mul24 takes the low 24 bits of each operand, sign-extended, and returns the
# low 32 bits of the product.
# The shuffle wrappers: name => the PTX mode the emitter uses (WARP_SHUFFLES: __nfcxx_shfl_<mode>_sync_i / _f).
SHFL_DEFS = {}
{ "bfly" => "xor", "down" => "down", "idx" => "" }.each do |mode, cuda|
  base = cuda.empty? ? "__shfl_sync" : "__shfl_#{cuda}_sync"
  ext = cuda.empty? ? "__nfcxx_shfl_sync" : "__nfcxx_shfl_#{cuda}_sync"
  SHFL_DEFS[mode] = <<-SHFL
extern "C" int #{ext}_i(unsigned, int, int);
extern "C" float #{ext}_f(unsigned, float, int);
static inline int #{base}(unsigned m, int v, int l) { (void)m; return #{ext}_i(0xffffffffu, v, l); }
static inline int #{base}(unsigned m, int v, int l, int w) { (void)m; (void)w; return #{ext}_i(0xffffffffu, v, l); }
static inline float #{base}(unsigned m, float v, int l) { (void)m; return #{ext}_f(0xffffffffu, v, l); }
static inline float #{base}(unsigned m, float v, int l, int w) { (void)m; (void)w; return #{ext}_f(0xffffffffu, v, l); }
  SHFL
end

# The half type and its conversions, shared by the entries below (include-guarded: each entry carries them, the
# device unit gets them once). __float2half rounds to nearest, even, as CUDA does; __half2float is exact.
HALF_CORE = "#ifndef __NFCXX_HALF_CORE\n#define __NFCXX_HALF_CORE\n" \
  "typedef unsigned short __half;\n" \
  "static inline unsigned short __float2half(float f) { unsigned x = *(const unsigned *)&f; unsigned sign = x & 0x80000000u; x ^= sign; unsigned o; if (x >= 0x47800000u) { o = x > 0x7f800000u ? 0x7e00u : 0x7c00u; } else if (x < 0x38800000u) { float t = *(const float *)&x * 16777216.0f; float r = (t + 8388608.0f) - 8388608.0f; o = (unsigned)r; } else { unsigned odd = (x >> 13) & 1u; x += (0u - 112u) * 0x800000u + 0xfffu; x += odd; o = x >> 13; } return (unsigned short)((sign >> 16) | o); }\n" \
  "static inline float __half2float(unsigned short h) { unsigned u = (unsigned)h; unsigned sign = (u & 0x8000u) << 16; unsigned e = (u >> 10) & 0x1fu; unsigned m = u & 0x3ffu; unsigned r; if (e == 0) { if (m == 0) { r = sign; } else { float f = (float)m * (1.0f / 16777216.0f); r = *(const unsigned *)&f | sign; } } else if (e == 31) { r = sign | 0x7f800000u | (m << 13); } else { r = sign | ((e + 112u) << 23) | (m << 13); } return *(const float *)&r; }\n" \
  "#endif\n"

# The integer intrinsics of llama.cpp's ggml-cuda. __umulhi, __popc and __byte_perm wrap the scalar intrinsics of the
# emitter (SCALAR_U32 in pathb-ptx-emit.rb, one PTX instruction each); the others are plain integer code. The half type
# is an unsigned short here (16-bit integers are lowered by the emitter), and the conversions do the IEEE work in 32-bit
# integers and float arithmetic: round to nearest, even, as CUDA's __float2half. __hadd, __hsub, __hmul and __hfma compute
# in float and round once more to half: for these operands the float result is exact or rounds the same way, except for
# rare double-rounding cases of __hfma (the sum of an exact product with c).
BUILTIN_DEFS = {
  "__mul24" => "static inline int __mul24(int x, int y) { int a = (int)((unsigned)x << 8) >> 8; int b = (int)((unsigned)y << 8) >> 8; return (int)((unsigned)a * (unsigned)b); }\n",
  "__umulhi" => "extern \"C\" unsigned __nfcxx_umulhi(unsigned, unsigned);\nstatic inline unsigned __umulhi(unsigned a, unsigned b) { return __nfcxx_umulhi(a, b); }\n",
  "__popc" => "extern \"C\" unsigned __nfcxx_popc(unsigned);\nstatic inline int __popc(unsigned x) { return (int)__nfcxx_popc(x); }\n",
  "__popcll" => "extern \"C\" unsigned __nfcxx_popc(unsigned);\nstatic inline int __popcll(unsigned long long x) { return (int)__nfcxx_popc((unsigned)x) + (int)__nfcxx_popc((unsigned)(x >> 32)); }\n",
  "__byte_perm" => "extern \"C\" unsigned __nfcxx_byte_perm(unsigned, unsigned, unsigned);\nstatic inline unsigned __byte_perm(unsigned x, unsigned y, unsigned s) { return __nfcxx_byte_perm(x, y, s); }\n",
  "__vsub4" => "static inline unsigned __vsub4(unsigned a, unsigned b) { unsigned r = 0; for (int i = 0; i < 4; i++) { unsigned sh = 8u * (unsigned)i; r |= ((((a >> sh) & 0xffu) - ((b >> sh) & 0xffu)) & 0xffu) << sh; } return r; }\n",
  "__vcmpne4" => "static inline unsigned __vcmpne4(unsigned a, unsigned b) { unsigned r = 0; for (int i = 0; i < 4; i++) { unsigned sh = 8u * (unsigned)i; if (((a >> sh) & 0xffu) != ((b >> sh) & 0xffu)) r |= 0xffu << sh; } return r; }\n",
  "__trap" => "static inline void __trap(void) { __builtin_trap(); }\n",
  # The warp shuffles (the emitter's WARP_SHUFFLES): int and float overloads, with and without the width. The mask and the
  # width are ignored: the wrapper is the full warp (width 32, mask 0xffffffff), because the emitter needs the constant
  # mask at the call and a wrapper's parameter is not one. Llama.cpp uses the full warp; a partial mask is not honoured.
  "__half" => HALF_CORE,
  "__float2half" => HALF_CORE,
  "__half2float" => HALF_CORE,
  "__hadd" => HALF_CORE + "static inline unsigned short __hadd(unsigned short a, unsigned short b) { return __float2half(__half2float(a) + __half2float(b)); }\n",
  "__hsub" => HALF_CORE + "static inline unsigned short __hsub(unsigned short a, unsigned short b) { return __float2half(__half2float(a) - __half2float(b)); }\n",
  "__hmul" => HALF_CORE + "static inline unsigned short __hmul(unsigned short a, unsigned short b) { return __float2half(__half2float(a) * __half2float(b)); }\n",
  "__hfma" => HALF_CORE + "static inline unsigned short __hfma(unsigned short a, unsigned short b, unsigned short c) { return __float2half(__half2float(a) * __half2float(b) + __half2float(c)); }\n",
  "__shfl_xor_sync" => SHFL_DEFS["bfly"],
  "__shfl_down_sync" => SHFL_DEFS["down"],
  "__shfl_sync" => SHFL_DEFS["idx"],
}

# The cooperative-groups names that the device code of scan, scalarProd and MC_EstimatePiP uses: a thread block
# group (cg::thread_block), cg::this_thread_block() and cg::sync(group). The group is a plain unsigned value here
# (it carries nothing), so no struct is passed by value. Methods on the group and tiled partitions are not
# provided: a unit that calls them still fails (simpleCooperativeGroups; tests/cuda/samples/README.md).
COOP_DEF = <<'COOP'
namespace cooperative_groups {
typedef unsigned int thread_block;
thread_block this_thread_block(void) { return 0u; }
void sync(thread_block) { __nfcxx_syncthreads(); }
}
namespace cg = cooperative_groups;
COOP

# Identifiers of a piece of code, outside literals and comments, in order.
def tokens_of(s)
  out = []
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "_" || (c.ord >= 65 && c.ord <= 90) || (c.ord >= 97 && c.ord <= 122)
      j = i
      j += 1 while j < s.length && ident_char?(s[j])
      out << s[i...j]
      i = j
    else
      i += 1
    end
  end
  out
end

# True if s has code outside comments and whitespace.
def code_only?(s)
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      if s[i] == "/"
        i = e
        next
      end
      return true
    end
    return true unless s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r"
    i += 1
  end
  false
end

# Top-level pieces of a translation unit: preprocessor lines, and declarations or definitions ending at a `;` or at
# the `}` of a function or namespace. Each piece is [start, stop, kind], kind :pp or :code, and :body if it has a
# brace block at depth 0.
def top_pieces(text)
  pieces = []
  n = text.length
  i = 0
  start = 0
  depth = 0
  paren0 = false
  body = false
  opener = nil   # text of the depth-0 `{`'s chunk start, to tell namespaces and extern "C" blocks
  while i < n
    if depth == 0 && text[i] == "#" && !code_only?(text[start...i])
      # a directive ends at a newline that is not in a comment or literal, or after a backslash
      k = i
      while k < n
        e2 = skip_literal(text, k)
        if e2
          k = e2
          next
        end
        break if text[k] == "\n" && text[k - 1] != "\\"
        k += 1
      end
      pieces << [i, k, :pp]
      i = k
      start = k
      next
    end
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    c = text[i]
    if c == "("
      paren0 = true if depth == 0
      depth += 1
    elsif c == "["
      depth += 1
    elsif c == ")" || c == "]"
      depth -= 1
    elsif c == "{"
      if depth == 0
        body = true
        opener = tokens_of(text[start...i]).first
      end
      depth += 1
    elsif c == "}"
      depth -= 1
      if depth == 0 && (opener == "namespace" || opener == "extern")
        pieces << [start, i + 1, :code, true]
        start = i + 1
        paren0 = false; body = false; opener = nil
      elsif depth == 0 && !(opener.nil?) && !%w[struct class union enum typedef using].include?(opener) && paren0
        pieces << [start, i + 1, :code, true]
        start = i + 1
        paren0 = false; body = false; opener = nil
      end
    elsif c == ";" && depth == 0
      pieces << [start, i + 1, :code, body]
      start = i + 1
      paren0 = false; body = false; opener = nil
    end
    i += 1
  end
  pieces << [start, n, :code, body] if text[start...n].strip != ""
  pieces
end

# Removes the whole words of `words` from s, outside literals and comments.
def remove_words(s, words)
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    hit = words.find { |w| word_at?(s, i, w) }
    if hit
      i += hit.length
      i += 1 while i < s.length && (s[i] == " " || s[i] == "\t")
      next
    end
    out << s[i]
    i += 1
  end
  out
end

# The name of the function a definition declares: the identifier before its first `(`.
def function_name(text)
  # the first `(` outside comments and literals
  paren = nil
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if text[i] == "("
      paren = i
      break
    end
    i += 1
  end
  return nil if paren.nil?
  head = text[0...paren].strip
  head.reverse.chars.take_while { |c| ident_char?(c) }.reverse.join
end

# Device mode: a quoted #include of a file that exists is replaced by that file's text (recursively, relative to the
# including file), so kernels kept in a .cu or .cuh of the same program are in the unit. System includes stay.
# Each file is expanded once per unit (`seen`, by absolute path): the headers of a CUDA backend include each other
# heavily, and without this the expansion repeats them at every branch (llama.cpp's mmq.cu grew to 24 MB, from 20 KB).
# Its include guards would drop the repeats anyway; a file meant to be included twice is not expanded twice.
def expand_includes(text, dir, depth, seen = {})
  return text if depth > 8
  out = ""
  last = 0
  top_pieces(text).each do |st, en, kind|
    next unless kind == :pp
    rest = text[st...en].sub("#", "").strip
    next unless rest.start_with?("include")
    q = rest[7..-1].to_s.strip
    next unless q.start_with?("\"")
    name = q[1..-1].split("\"")[0].to_s
    path = dir + "/" + name
    next unless File.exist?(path)
    key = File.expand_path(path)
    out << text[last...st]
    if seen[key]
      out << "\n"
    else
      seen[key] = true
      # The same two rewrites as the main file: a header of the backend has __launch_bounds__ in front of its
      # template kernels, which kernel_template would not match.
      inc = dynamic_shared_rewrite(strip_launch_bounds(File.open(path, "rb") { |f| f.read }))
      out << "\n" << expand_includes(inc, File.dirname(path), depth + 1, seen) << "\n"
    end
    last = en
  end
  out << text[last..-1].to_s
  out
end

# Returns [device translation unit text, kernel names].
#
# The unit has the prelude, every __global__ and __device__ function definition or declaration, and the host
# declarations that those reference, transitively: typedefs, using, struct/class/union/enum definitions, variables,
# and #define/#undef. Host function definitions are not carried over, and neither are the #include lines (their
# contents are not in the unit; a name they supply is a missing declaration, reported by the front end). The
# conditional directives (#if, #ifdef, ...) are kept as written. A __device__ variable is refused: device data is
# not lowered yet.
# ---- conditionals of the device pass

# An expression the evaluator does not handle (a float literal, a string, a call with odd arguments): the conditional
# is kept as it was, with its lines and both branches, as before the evaluator existed.
class CondUnsupported < StandardError
end

def cond_fail(msg)
  raise CondUnsupported, msg
end
#
# The device unit is cut into top-level pieces by brace counting, and a preprocessor conditional opens or closes
# braces in the text of both of its branches, so a kernel inside #if/#else never returns the count to zero. The
# device pass therefore evaluates the conditionals first: the branches not taken are blanked (the line count is
# kept), the #if/#ifdef/#else/#endif lines are removed, and #define and #undef of the taken branches stay.
# The device pass defines CUDA's device-compile macros; the host pass is not affected.
DEVICE_PASS_MACROS = { "__CUDACC__" => "1", "__NVCC__" => "1", "__CUDA_ARCH__" => "750" }

def cond_tokens(s, line)
  toks = []
  i = 0
  n = s.length
  while i < n
    c = s[i]
    if white?(c)
      i += 1
    elsif ident_char?(c)
      j = i
      j += 1 while j < n && ident_char?(s[j])
      w = s[i...j]
      if c.ord >= 48 && c.ord <= 57
        w = w[0...-1] while w.length > 0 && "uUlL".include?(w[-1])
        v = (w.length > 2 && w[0] == "0" && (w[1] == "x" || w[1] == "X")) ? w[2..-1].to_i(16) : w.to_i
        toks << [:num, v]
      else
        toks << [:id, w]
      end
      i = j
    else
      two = i + 1 < n ? s[i, 2] : ""
      if %w[&& || == != <= >= << >>].include?(two)
        toks << [:op, two]
        i += 2
      elsif "!~+-*/%<>&|^()?:,".include?(c)
        toks << [:op, c]
        i += 1
      else
        cond_fail("unsupported character #{c.inspect} in #if at line #{line}")
      end
    end
  end
  toks
end

# Evaluates a #if expression: integers, identifiers (their object-like macro value, else 0), defined(X), the usual C
# operators. An unknown function-like call, such as __has_include(...), counts as 0.
def cond_eval(s, defs, line, depth = 0)
  cond_fail("#if nesting too deep at line #{line}") if depth > 16
  st = { toks: cond_tokens(s, line), pos: 0 }
  v = cond_expr(st, defs, line, depth)
  cond_fail("unsupported #if expression at line #{line}") if st[:pos] != st[:toks].length
  v
end

def cond_peek(st, x = nil)
  t = st[:toks][st[:pos]]
  return false if t.nil?
  return false if x && !(t[0] == :op && t[1] == x)
  true
end

def cond_expr(st, defs, line, depth)
  c = cond_binary(st, defs, line, depth, 0)
  return c unless cond_peek(st, "?")
  st[:pos] += 1
  a = cond_expr(st, defs, line, depth)
  cond_fail("expected ':' in #if at line #{line}") unless cond_peek(st, ":")
  st[:pos] += 1
  b = cond_expr(st, defs, line, depth)
  c != 0 ? a : b
end

# Binary operators by precedence level, lowest first.
COND_LEVELS = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

def cond_binary(st, defs, line, depth, level)
  return cond_unary(st, defs, line, depth) if level >= COND_LEVELS.length
  l = cond_binary(st, defs, line, depth, level + 1)
  loop do
    t = st[:toks][st[:pos]]
    break unless t && t[0] == :op && COND_LEVELS[level].include?(t[1])
    op = t[1]
    st[:pos] += 1
    if op == "||"
      r = cond_binary(st, defs, line, depth, level + 1)
      l = (l != 0 || r != 0) ? 1 : 0
    elsif op == "&&"
      r = cond_binary(st, defs, line, depth, level + 1)
      l = (l != 0 && r != 0) ? 1 : 0
    else
      r = cond_binary(st, defs, line, depth, level + 1)
      l = case op
          when "|" then l | r
          when "^" then l ^ r
          when "&" then l & r
          when "==" then l == r ? 1 : 0
          when "!=" then l != r ? 1 : 0
          when "<" then l < r ? 1 : 0
          when ">" then l > r ? 1 : 0
          when "<=" then l <= r ? 1 : 0
          when ">=" then l >= r ? 1 : 0
          when "<<" then l << r
          when ">>" then l >> r
          when "+" then l + r
          when "-" then l - r
          when "*" then l * r
          when "/" then (r == 0 ? cond_fail("division by zero in #if at line #{line}") : l / r)
          when "%" then (r == 0 ? cond_fail("division by zero in #if at line #{line}") : l % r)
          end
    end
  end
  l
end

def cond_unary(st, defs, line, depth)
  t = st[:toks][st[:pos]]
  cond_fail("unexpected end of #if expression at line #{line}") if t.nil?
  if t[0] == :op && t[1] == "!"
    st[:pos] += 1
    return cond_unary(st, defs, line, depth) == 0 ? 1 : 0
  elsif t[0] == :op && t[1] == "-"
    st[:pos] += 1
    return -cond_unary(st, defs, line, depth)
  elsif t[0] == :op && t[1] == "+"
    st[:pos] += 1
    return cond_unary(st, defs, line, depth)
  elsif t[0] == :op && t[1] == "~"
    st[:pos] += 1
    return ~cond_unary(st, defs, line, depth)
  elsif t[0] == :op && t[1] == "("
    st[:pos] += 1
    v = cond_expr(st, defs, line, depth)
    cond_fail("expected ')' in #if at line #{line}") unless cond_peek(st, ")")
    st[:pos] += 1
    return v
  elsif t[0] == :num
    st[:pos] += 1
    return t[1]
  elsif t[0] == :id && t[1] == "defined"
    st[:pos] += 1
    paren = cond_peek(st, "(")
    st[:pos] += 1 if paren
    name = st[:toks][st[:pos]]
    cond_fail("defined without a name at line #{line}") unless name && name[0] == :id
    st[:pos] += 1
    if paren
      cond_fail("expected ')' after defined at line #{line}") unless cond_peek(st, ")")
      st[:pos] += 1
    end
    return defs.key?(name[1]) ? 1 : 0
  elsif t[0] == :id
    st[:pos] += 1
    if cond_peek(st, "(")
      # a call of a function-like macro or an unknown function: 0, with its arguments skipped
      st[:pos] += 1
      nest = 1
      while nest > 0
        u = st[:toks][st[:pos]]
        cond_fail("unbalanced parentheses in #if at line #{line}") if u.nil?
        nest += 1 if u[0] == :op && u[1] == "("
        nest -= 1 if u[0] == :op && u[1] == ")"
        st[:pos] += 1
      end
      return 0
    end
    val = defs[t[1]]
    return 0 if val.nil? || val == :function
    return cond_eval(val, defs, line, depth + 1)
  end
  cond_fail("unsupported #if expression at line #{line}")
end

# Resolves the conditionals of a translation unit. defs maps a name to its object-like replacement text, a function-like
# macro to :function, and a macro with no value to "". A conditional that cannot be evaluated (CondUnsupported) is
# kept with its branches; the lines of the other conditionals are blanked, so the line count does not change.
def resolve_conditionals(text, defs)
  out = []
  stack = []
  active = true
  pending = nil
  lineno = 0
  text.split("\n", -1).each do |raw|
    lineno += 1
    line = raw
    if pending
      line = pending + "\n" + raw
      pending = nil
    end
    if line.end_with?("\\")
      pending = line[0...-1]
      out << ""
      next
    end
    s = line.lstrip
    unless s.start_with?("#")
      out << (active ? line : "")
      next
    end
    d = s[1..-1].lstrip
    name = ""
    k = 0
    while k < d.length && ident_char?(d[k])
      name += d[k]
      k += 1
    end
    rest = d[k..-1].to_s.strip
    case name
    when "if", "ifdef", "ifndef"
      parent = active
      begin
        if name == "if"
          cond = parent ? cond_eval(rest, defs, lineno) != 0 : false
        else
          nm = rest.split(" ")[0].to_s
          cond = parent ? (defs.key?(nm) == (name == "ifdef")) : false
        end
        stack << { parent: parent, taken: cond, kept: false }
        active = parent && cond
        out << ""
      rescue CondUnsupported
        stack << { parent: parent, taken: true, kept: true }
        active = parent
        out << (parent ? line : "")
      end
    when "elif"
      refuse("#elif without #if at line #{lineno}") if stack.empty?
      fr = stack.last
      if fr[:kept]
        out << (fr[:parent] ? line : "")
      elsif fr[:taken]
        active = false
        out << ""
      else
        begin
          cond = fr[:parent] ? cond_eval(rest, defs, lineno) != 0 : false
          fr[:taken] = cond
          active = fr[:parent] && cond
          out << ""
        rescue CondUnsupported
          fr[:kept] = true
          fr[:taken] = true
          active = fr[:parent]
          out << (fr[:parent] ? line : "")
        end
      end
    when "else"
      refuse("#else without #if at line #{lineno}") if stack.empty?
      fr = stack.last
      if fr[:kept]
        out << (fr[:parent] ? line : "")
      else
        active = fr[:parent] && !fr[:taken]
        fr[:taken] = true
        out << ""
      end
    when "endif"
      refuse("#endif without #if at line #{lineno}") if stack.empty?
      fr = stack.pop
      active = fr[:parent]
      out << (fr[:kept] && fr[:parent] ? line : "")
    when "define"
      if active
        mname = ""
        j = 0
        while j < rest.length && ident_char?(rest[j])
          mname += rest[j]
          j += 1
        end
        if rest[j] == "("
          defs[mname] = :function
        else
          defs[mname] = rest[j..-1].to_s.strip
        end
      end
      out << (active ? line : "")
    when "undef"
      defs.delete(rest.split(" ")[0].to_s) if active
      out << (active ? line : "")
    else
      out << (active ? line : "")
    end
  end
  refuse("#if without #endif") unless stack.empty?
  out.join("\n")
end

def device_tu(text)
  pieces = top_pieces(text).map do |pc|
    st, en, kind, body = pc
    t = text[st...en]
    info = { text: t, kind: kind, body: body, toks: tokens_of(t), defined: [], keep: false, device: false }
    if kind == :pp
      rest = t.sub("#", "").gsub("\n", " ").strip
      d = rest.split(" ")[0] || ""
      if d == "define"
        after = rest[6..-1].strip
        name = after.split(" ")[0].to_s.split("(")[0]
        info[:defined] = [name]
        info[:toks] = tokens_of(after[name.length..-1].to_s)
        info[:macro] = true
      elsif d == "undef"
        info[:keep] = true
      elsif %w[if ifdef ifndef elif else endif].include?(d)
        info[:keep] = true
      end
    else
      info[:device] = info[:toks].include?("__global__") || info[:toks].include?("__device__")
    end
    info
  end

  kernels = []
  seeds = []
  # The template launches of the source: each instance is a wrapper kernel (see template_site).
  # A launch whose template arguments depend on an enclosing template parameter is not a wrapper: its instance is
  # fixed only by the instantiation, and the host pass refuses it (see rewrite). Registering it here would give a
  # wrapper that still names the parameter.
  template_launches(text).each { |nm, ta, pos| template_site(nm, ta) if dependent_on_template(text, pos, ta).nil? }
  pieces.each do |pc|
    next if pc[:kind] == :pp
    if pc[:device]
      if pc[:text].include?("__device__") && !pc[:body] && !pc[:text].include?("(")
        refuse("device variable: #{pc[:text].strip[0, 60]}")
      end
      if pc[:body]
        if pc[:toks].include?("__global__") && pc[:toks].first != "template"
          name = function_name(remove_words(pc[:text], DEVICE_QUALIFIERS))
          refuse("kernel without a name: #{pc[:text].strip[0, 60]}") if name.nil? || name.empty?
          kernels << name
        end
        pc[:keep] = true
        pc[:text] = remove_words(pc[:text], DEVICE_QUALIFIERS)
        seeds.concat(pc[:toks])
      elsif pc[:text].include?("(")
        pc[:keep] = true
        pc[:text] = remove_words(pc[:text], DEVICE_QUALIFIERS)
        seeds.concat(pc[:toks])
      end
    end
  end

  # Host declarations: defined names, as far as a piece's text tells them.
  pieces.each do |pc|
    next if pc[:keep] || pc[:device]
    t = pc[:text]
    toks = pc[:toks]
    if pc[:kind] == :pp
      next unless pc[:macro]
      next
    end
    next if toks.empty?
    next if pc[:body] && t.index("(") && !toks.include?("struct") && !toks.include?("class") && !toks.include?("union") && !toks.include?("enum")
    next if !pc[:body] && t.index("(") && !t.index("=") # host prototype
    if toks.first == "typedef"
      pc[:defined] = [toks.last]
    elsif toks.first == "using"
      pc[:defined] = [toks[1]].compact
    elsif (kw = (toks & %w[struct class union enum]).first)
      k = toks.index(kw)
      pc[:defined] = [toks[k + 1]].compact
      pc[:defined] += toks if kw == "enum"   # the enumerators: over-approximated by every identifier
    elsif pc[:body]
      next
    elsif toks.include?("const") || toks.include?("constexpr")
      # a constant: device code may read it. Other host variables are not reachable from device code.
      cut = t.index("=") || t.index("[") || t.index(";") || t.length
      pc[:defined] = [tokens_of(t[0...cut]).last].compact
    end
  end

  # Fixed point: a host declaration is carried over when the unit refers to a name it defines.
  needed = {}
  (seeds + tokens_of(DEVICE_PRELUDE)).each { |x| needed[x] = true }
  changed = true
  while changed
    changed = false
    pieces.each do |pc|
      next if pc[:keep] || pc[:device]
      next if pc[:defined].empty?
      next unless pc[:defined].any? { |d| needed[d] }
      pc[:keep] = true
      changed = true
      pc[:toks].each { |x| needed[x] = true }
    end
  end
  pieces.each do |pc|
    next unless pc[:kind] == :pp && pc[:macro] && pc[:defined].any? { |d| needed[d] }
    pc[:keep] = true
  end

  out = "// Device side of a .cu file, generated by scripts/cuda-rewrite.rb --device. Do not edit.\n"
  out << DEVICE_PRELUDE << device_decls << "\n"
  # A vector type the device code names, and the source does not define: its declaration (once per type).
  done = {}
  VECTOR_DEFS.each do |name, text|
    next unless needed[name]
    next if pieces.any? { |pc| pc[:keep] && pc[:defined].include?(name) }
    base = name.start_with?("make_") ? name[5..-1] : name
    next if done[base]
    done[base] = true
    out << VECTOR_DEFS[base] << "\n"
  end
  BUILTIN_DEFS.each do |name, text|
    next unless needed[name]
    next if pieces.any? { |pc| pc[:keep] && pc[:defined].include?(name) }
    out << text
  end
  if (needed["cg"] || needed["cooperative_groups"]) && pieces.none? { |pc| pc[:keep] && pc[:defined].include?("cooperative_groups") }
    out << COOP_DEF
  end
  pieces.each do |pc|
    next unless pc[:keep]
    out << rewrite_builtins(pc[:text]) << "\n"
  end
  $sites.each do |w, site|
    out << "extern \"C\" void #{w}(#{site[:decl]}) { #{site[:name]}<#{site[:targs]}>(#{site[:call].join(", ")}); }\n"
    kernels << w
  end
  [out, kernels.uniq]
end

# __launch_bounds__(...) is a compile hint (register and occupancy limits). The launch path does not use it, so it
# is removed with its argument list, host and device units alike. Literals and comments are skipped.
def strip_launch_bounds(s)
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if word_at?(s, i, "__launch_bounds__")
      j = i + "__launch_bounds__".length
      j += 1 while j < s.length && white?(s[j])
      if j < s.length && s[j] == "("
        close = matching_paren(s, j)
        refuse("unterminated __launch_bounds__") if close.nil?
        # keep the newlines inside the argument list, so line numbers do not move
        out << ("\n" * s[i..close].count("\n"))
        i = close + 1
        next
      end
    end
    out << s[i]
    i += 1
  end
  out
end

# Dynamic shared memory: `extern __shared__ T name[];` has no size at compile time (the launch gives the bytes), so
# the declaration is removed and each `name[...]` becomes a subscript of a pointer from __nfcxx_dynshared_addr(),
# the block's dynamic shared memory. The device side lowers that call to the address of a module-level
# `.extern .shared` symbol (the emitter's job); the host copy has a placeholder (lib/cuda/nfcxx_cuda.h). A pointer
# subscript has no bounds check, which is right: the size is only known at launch.
def dynamic_shared_rewrite(s)
  names = {}
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if word_at?(s, i, "extern")
      j = i + 6
      j += 1 while j < s.length && white?(s[j])
      if word_at?(s, j, "__shared__")
        k = j + 10
        semi = s.index(";", k)
        refuse("extern __shared__ declaration without ';'") if semi.nil?
        decl = s[k...semi].strip
        m = decl.rindex("[")
        refuse("extern __shared__ #{decl}: only an unsized array (T name[]) is dynamic shared memory") unless m && decl.end_with?("]") && decl[(m + 1)...-1].strip.empty?
        head = decl[0...m].strip
        q = head.length
        q -= 1 while q > 0 && ident_char?(head[q - 1])
        name = head[q...head.length]
        type = head[0...q].strip
        refuse("extern __shared__ #{decl}: no type or name") if name.empty? || type.empty?
        names[name] = type
        out << ("\n" * s[i..semi].count("\n"))
        i = semi + 1
        next
      end
    end
    out << s[i]
    i += 1
  end
  return out if names.empty?
  replace_dynamic_uses(out, names)
end

# Replaces the uses `name[` of the dynamic shared arrays. A member (`.name`, `->name`) is not a use.
def replace_dynamic_uses(s, names)
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if ident_char?(s[i]) && !(s[i] >= "0" && s[i] <= "9")
      j = i
      j += 1 while j < s.length && ident_char?(s[j])
      tok = s[i...j]
      q = i - 1
      q -= 1 while q >= 0 && white?(s[q])
      member = q >= 0 && (s[q] == "." || (s[q] == ">" && q > 0 && s[q - 1] == "-"))
      n = j
      n += 1 while n < s.length && white?(s[n])
      if names.key?(tok) && !member && s[n] == "["
        out << "((#{names[tok]} *)__nfcxx_dynshared_addr())"
        i = j
        next
      end
      out << tok
      i = j
      next
    end
    out << s[i]
    i += 1
  end
  out
end

def usage
  $stderr.puts "usage: cuda-rewrite.rb [--device [--kernels=FILE]] FILE.cu"
  exit(2)
end

device = false
kernels_path = nil
path = nil
# The host copy of a unit gives each kernel internal linkage (static), as nvcc does: two translation units that
# include the same header with a kernel must not define the same host symbol. The embedded registration of each
# unit refers to its own host copy. Literals and comments are skipped; only the whole identifier is replaced.
# The storage keyword a host copy gets: `static`, unless the declaration already has one (then the qualifier goes).
def host_storage(out, kw)
  head = out.rstrip
  already = head.end_with?("static") && (head.length == 6 || !ident_char?(head[-7]))
  already ? "" : kw
end

def host_linkage(text)
  out = ""
  i = 0
  word = "__global__"
  while i < text.length
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if text[i, word.length] == word && !(i > 0 && ident_char?(text[i - 1])) && !ident_char?(text[i + word.length])
      out << host_storage(out, "static")
      i += word.length
      next
    end
    # A __device__ function (not a variable) is device-only code, but its host copy would still be an external symbol:
    # the same header in two units would define it twice. Its host copy is static too.
    if text[i, 8] == "__device" && !(i > 0 && ident_char?(text[i - 1])) && text[i, 10] == "__device__" &&
       !ident_char?(text[i + 10])
      j = i + 10
      j += 1 while j < text.length && (text[j] == " " || text[j] == "\n" || text[j] == "\t")
      k = j
      k += 1 while k < text.length && !"(=;{".include?(text[k])
      if k < text.length && text[k] == "("
        # `__device__ static T f(...)`: the keyword after the qualifier already gives the storage class.
        after_static = text[j, 6] == "static" && !ident_char?(text[j + 6])
        out << (after_static ? "" : host_storage(out, "static"))
        i += 10
        next
      end
    end
    out << text[i]
    i += 1
  end
  out
end

ARGV.each do |a|
  if a == "--device"
    device = true
  elsif a.start_with?("--kernels=")
    kernels_path = a[10..-1]
  elsif path.nil?
    path = a
  else
    usage
  end
end
usage if path.nil?
text = File.open(path, "rb") { |f| f.read }
text = dynamic_shared_rewrite(strip_launch_bounds(text))
$expanded = expand_includes(text, File.dirname(path), 0)
if device
  # The device unit is built from the conditionals of the device pass (see resolve_conditionals).
  defs = {}
  DEVICE_PASS_MACROS.each { |k, v| defs[k] = v }
  $expanded = resolve_conditionals($expanded, defs)
  dev, kernels = device_tu($expanded)
  File.open(kernels_path, "wb") { |f| f.write(kernels.map { |k| k + "\n" }.join) } unless kernels_path.nil?
  print dev
else
  # The host copy has the local headers expanded too: their launches are in the host unit as well.
  print host_linkage(rewrite($expanded, path))
end
