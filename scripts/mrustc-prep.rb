# Rewrite the C that mrustc's C backend emits so cproc accepts it, and keep what cproc would otherwise lose. Run on
# the output of `cc -E -P -D__CPROC__` (not -undef: that makes glibc drop the GNU attributes). scripts/qbe-cc then
# does the rest (qbe-prep, cproc, QBE, assembling). scripts/mrustc-nfcc.sh does all of it. The forms rewritten,
# the rest passes through unchanged:
#
#   * `_Atomic` qualifier (from <stdatomic.h>), `__extension__` and `__restrict` (the C99 spelling, which cproc reads).
#   * Attributes: the trailing comma in `__attribute__((__aligned__(16),))` is dropped on attribute lines only (`,)`
#     also occurs in string literals). A `#pragma pack(push, 1)` struct gets `packed` after its keyword (cproc ignores
#     #pragma, and reads the attribute only there).
#   * `__mrustc_atomicloop{8,16,32,64}`, mrustc's fetch-op loop (one prelude line each): the same loop over the sized
#     `__atomic_load_N` and `__atomic_compare_exchange_N`, which qbe-prep declares and libatomic provides.
#   * Atomic loads, stores, exchanges and compare-exchanges in GNU statement expressions (`atomic_expr`): the same
#     operation over the sized builtins, or over the generic libatomic calls for the 16-byte `uint128_t` (helpers
#     after its typedef).
#   * mrustc's placeholders for intrinsics it does not implement, `({ if (!"MSG") ; else __assert_fail (...); })`,
#     as the conditional expression they are equivalent to. `__PRETTY_FUNCTION__` becomes `__func__`.
#   * Inline asm libcore uses (`pause`, `xgetbv`, `cpuid`): `pause` is dropped, the other two call helpers of the tail.
#     glibc's redirect of strerror_r is dropped (libcore only declares it). Any other asm statement whose operands are
#     variables is outlined into a helper of the asm.c output, which the host C compiler builds (asm_outline).
#   * An extern function whose symbol is named by an asm label, `extern T ZRG...(...)` then `asm("__rust_alloc");`:
#     the label leaves the C, and the tail defines the mangled name as a jump to it (weak, so every object may carry
#     it). Only functions; a label on anything else stops the rewrite. ELF only: no leading underscore on symbols.
#   * Weak data (`__attribute__((weak))` on vtables and type ids, which cproc ignores): the names go to the weak file,
#     and scripts/mrustc-nfcc.sh weakens them in the object (`objcopy --weaken-symbols`, which must be in the same
#     object as the definition).
#
# The script uses no regular expressions, so it runs on the self-built mruby (scripts/mrb), as qbe-prep does.
# Usage: scripts/mrb scripts/mrustc-prep.rb in.c out.c tail.s weak.txt [asm.c]

IDENT_CHARS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'

def fail_with(msg)
  $stderr.puts "mrustc-prep: #{msg}"
  exit 1
end

# mrustc's placeholder for an intrinsic it does not implement is a GNU statement expression that aborts when it runs:
#   ({ if (!"MSG") ; else __assert_fail ("MSG", "FILE", LINE, __PRETTY_FUNCTION__); })
# It has no value, so the same test as a conditional expression is equivalent and cproc accepts it:
#   (!"MSG" ? (void)0 : __assert_fail ("MSG", "FILE", LINE, __PRETTY_FUNCTION__))
ASSERT_IF = '({ if ('
ASSERT_ELSE = ') ; else __assert_fail ('
ASSERT_END = '); })'

def rewrite_assert_stmt_exprs(line)
  out = ''
  rest = line
  while (s = rest.index(ASSERT_IF)) != nil
    cond_start = s + ASSERT_IF.bytesize
    fail_with("statement expression that is not the assert form: #{line}") unless rest.byteslice(cond_start, 2) == '!"'
    e = rest.index(ASSERT_ELSE, cond_start)
    fail_with("assert form without its else branch: #{line}") if e.nil?
    args_start = e + ASSERT_ELSE.bytesize
    x = rest.index(ASSERT_END, args_start)
    fail_with("assert form without its end: #{line}") if x.nil?
    cond = rest.byteslice(cond_start, e - cond_start)
    args = rest.byteslice(args_start, x - args_start)
    out << rest.byteslice(0, s) << "(#{cond} ? (void)0 : __assert_fail (#{args}))"
    rest = rest.byteslice(x + ASSERT_END.bytesize, rest.bytesize - x - ASSERT_END.bytesize)
  end
  out << rest
end

# mrustc's atomic loads, stores, exchanges and compare-exchanges on libcore's integer types are GNU statement
# expressions over the generic __atomic builtins, with a temporary of the pointee type (see `atomic_expr`). Each
# becomes an expression over the sized builtin of the same width, which cproc calls as a function (qbe-prep
# declares it), with a cast to the pointee type where a value comes back.
ATOMIC_HEAD = '({ __auto_type __atomic_'
ATOMIC_SIZE = {
  'int8_t' => 1, 'uint8_t' => 1, 'int16_t' => 2, 'uint16_t' => 2, 'int32_t' => 4, 'uint32_t' => 4,
  'int64_t' => 8, 'uint64_t' => 8, 'intptr_t' => 8, 'uintptr_t' => 8
}

# The 16-byte type (a struct in mrustc's prelude, not a builtin integer). Its atomics go through the generic libatomic
# calls, which take the size, in the helpers below. They follow the prelude's typedef, which declares the type.
WIDE_ATOMIC_TYPE = 'uint128_t'
WIDE_ATOMIC_TYPEDEF = 'typedef struct { uint64_t lo, hi; } uint128_t;'
WIDE_ATOMIC_HELPERS = <<'HELPERS'
extern _Bool __atomic_compare_exchange (unsigned long, void *, void *, void *, int, int);
extern void __atomic_load (unsigned long, void *, void *, int);
extern void __atomic_store (unsigned long, void *, void *, int);
extern void __atomic_exchange (unsigned long, void *, void *, void *, int);
static inline uint128_t __nfcxx_atomic_load16 (volatile void *p, int o) { uint128_t r; __atomic_load (16, (void *)p, &r, o); return r; }
static inline void __nfcxx_atomic_store16 (volatile void *p, uint128_t v, int o) { __atomic_store (16, (void *)p, &v, o); }
static inline uint128_t __nfcxx_atomic_exchange16 (volatile void *p, uint128_t v, int o) { uint128_t r; __atomic_exchange (16, (void *)p, &v, &r, o); return r; }
static inline _Bool __nfcxx_atomic_compare_exchange16 (volatile void *p, void *e, uint128_t d, int s, int f) { return __atomic_compare_exchange (16, (void *)p, e, &d, s, f); }
HELPERS

# The arguments of a call `name (a, b, c)` (the text of `stmt`), split at the commas outside parentheses.
def call_args(stmt, name)
  fail_with("expected a call of #{name}: #{stmt}") unless stmt.byteslice(0, name.bytesize + 2) == "#{name} ("
  inside = stmt.byteslice(name.bytesize + 2, stmt.bytesize - name.bytesize - 3)
  args = []
  depth = 0
  cur = ''
  i = 0
  while i < inside.bytesize
    c = inside.byteslice(i, 1)
    if c == ',' && depth == 0
      args << cur.strip
      cur = ''
    else
      depth += 1 if c == '('
      depth -= 1 if c == ')'
      cur << c
    end
    i += 1
  end
  args << cur.strip
  args
end

# The text after ` = ` of a declaration `__typeof__ ((void)0, *P) TMP = V`, and the name TMP.
def tmp_decl(decl)
  eq = decl.index(' = ')
  fail_with("expected a temporary declaration: #{decl}") if eq.nil?
  [decl.byteslice(0, eq).split(' ').last, decl.byteslice(eq + 3, decl.bytesize - eq - 3).strip]
end

# The C expression for one atomic statement expression, given its body (the statements between `({` and `})`).
def atomic_expr(body)
  stmts = body.split(';').map { |s| s.strip }.reject { |s| s.empty? }
  head = stmts[0].to_s
  prefix = '__auto_type __atomic_'
  fail_with("atomic statement expression without its pointer: #{body}") unless head.byteslice(0, prefix.bytesize) == prefix
  decl = head.byteslice(prefix.bytesize, head.bytesize - prefix.bytesize)
  ptr_at = decl.index('_ptr = ((')
  fail_with("atomic statement expression without its pointer: #{body}") if ptr_at.nil?
  op = decl.byteslice(0, ptr_at)
  typed = decl.byteslice(ptr_at + 9, decl.bytesize - ptr_at - 9)
  star = typed.index('*)')
  fail_with("atomic pointer of an unknown form: #{body}") if star.nil?
  t = typed.byteslice(0, star).strip
  a = typed.byteslice(star + 2, typed.bytesize - star - 2).strip
  fail_with("atomic pointer of an unknown form: #{body}") unless a.byteslice(a.bytesize - 1, 1) == ')'
  a = a.byteslice(0, a.bytesize - 1).strip
  # An atomic pointer is one of pointer width; its value is passed to the sized builtin as an integer.
  ptr = t.byteslice(t.bytesize - 1, 1) == '*'
  n = ptr ? 8 : ATOMIC_SIZE[t]
  vcast = ptr ? "(unsigned long)" : ""
  wide = t == WIDE_ATOMIC_TYPE
  fail_with("atomic on #{t}, which has no builtin here: #{body}") if n.nil? && !wide
  vptr = "(volatile void *)(#{a})"
  case op
  when 'load'
    fail_with("unexpected atomic load: #{body}") unless stmts.size == 4
    fail_with("unexpected atomic load temporary: #{body}") unless stmts[1].byteslice(0, 12) == '__typeof__ ('
    o = call_args(stmts[2], '__atomic_load')[2]
    wide ? "__nfcxx_atomic_load16 (#{vptr}, #{o})" : "((#{t}) __atomic_load_#{n} (#{vptr}, #{o}))"
  when 'store'
    fail_with("unexpected atomic store: #{body}") unless stmts.size == 3
    _, v = tmp_decl(stmts[1])
    o = call_args(stmts[2], '__atomic_store')[2]
    wide ? "__nfcxx_atomic_store16 (#{vptr}, (#{v}), #{o})" : "__atomic_store_#{n} (#{vptr}, #{vcast}(#{v}), #{o})"
  when 'exchange'
    fail_with("unexpected atomic exchange: #{body}") unless stmts.size == 5
    _, v = tmp_decl(stmts[1])
    o = call_args(stmts[3], '__atomic_exchange')[3]
    wide ? "__nfcxx_atomic_exchange16 (#{vptr}, (#{v}), #{o})" : "((#{t}) __atomic_exchange_#{n} (#{vptr}, #{vcast}(#{v}), #{o}))"
  when 'compare_exchange'
    fail_with("unexpected atomic compare-exchange: #{body}") unless stmts.size == 3
    _, v = tmp_decl(stmts[1])
    args = call_args(stmts[2], '__atomic_compare_exchange')
    fail_with("unexpected atomic compare-exchange arguments: #{body}") unless args.size == 6 && (args[3] == '0' || args[3] == '1')
    e = "(void *)(#{args[1]})"
    wide ? "__nfcxx_atomic_compare_exchange16 (#{vptr}, #{e}, (#{v}), #{args[4]}, #{args[5]})" :
           "((_Bool) __atomic_compare_exchange_#{n} (#{vptr}, #{e}, #{vcast}(#{v}), #{args[3]}, #{args[4]}, #{args[5]}))"
  else
    fail_with("atomic #{op} is not one of load, store, exchange and compare_exchange: #{body}")
  end
end

# Every atomic statement expression on the line replaced by its expression (see atomic_expr).
def rewrite_atomic_stmt_exprs(line)
  out = ''
  rest = line
  while (s = rest.index(ATOMIC_HEAD)) != nil
    open = s + 1   # the `{` after the `(`
    depth = 0
    close = nil
    i = open
    while i < rest.bytesize
      c = rest.byteslice(i, 1)
      if c == '{'
        depth += 1
      elsif c == '}'
        depth -= 1
        if depth == 0
          close = i
          break
        end
      end
      i += 1
    end
    fail_with("unterminated atomic statement expression: #{line}") if close.nil? || rest.byteslice(close + 1, 1) != ')'
    out << rest.byteslice(0, s) << atomic_expr(rest.byteslice(open + 1, close - open - 1))
    rest = rest.byteslice(close + 2, rest.bytesize - close - 2)
  end
  out << rest
end

# Every occurrence of the whole token `word` (not part of a longer identifier) replaced by `repl`.
def replace_word(line, word, repl)
  out = ''
  rest = line
  while (i = rest.index(word)) != nil
    before = i > 0 ? rest.byteslice(i - 1, 1) : ' '
    j = i + word.bytesize
    after = j < rest.bytesize ? rest.byteslice(j, 1) : ' '
    if IDENT_CHARS.index(before) || IDENT_CHARS.index(after)
      out << rest.byteslice(0, j)
    else
      out << rest.byteslice(0, i) << repl
    end
    rest = rest.byteslice(j, rest.bytesize - j)
  end
  out << rest
end

# The fetch-op loop for one width. `n` is the width in bytes, which names the libatomic function.
def atomicloop(bits)
  t = "uint#{bits}_t"
  n = bits / 8
  "static inline #{t} __mrustc_atomicloop#{bits}(volatile #{t}* slot, #{t} param, int ordering, #{t} (*cb)(#{t}, #{t})) { " \
  "int ordering_load = (ordering == memory_order_release || ordering == memory_order_acq_rel ? memory_order_relaxed : ordering); " \
  "for(;;) { #{t} v = __atomic_load_#{n}(slot, ordering_load); #{t} desired = cb(v, param); " \
  "if( __atomic_compare_exchange_#{n}(slot, &v, desired, 0, ordering, ordering_load) ) return v; } }"
end

ATOMICLOOP_HEAD = {}
[8, 16, 32, 64].each do |bits|
  ATOMICLOOP_HEAD["static inline uint#{bits}_t __mrustc_atomicloop#{bits}("] = atomicloop(bits)
end

# mrustc marks monomorphised statics (vtables) and type ids weak: `__attribute__((weak)) union {...} NAME;`, or
# `T NAME __attribute__((weak));`. cproc ignores the attribute on data, so the name is returned for the tail to mark
# weak (the same objects are linked with other crates' copies). Functions are left to weak-symbols.rb (they have a
# parenthesis in the line).
WEAK_ATTR = '__attribute__((weak))'

# The identifier at the end of `s`. `$` is part of mrustc's mangled names (a hash after it), as qbe-prep's scanner has it.
def trailing_ident(s)
  i = s.bytesize
  i -= 1 while i > 0 && (IDENT_CHARS.index(s.byteslice(i - 1, 1)) || s.byteslice(i - 1, 1) == '$')
  name = s.byteslice(i, s.bytesize - i)
  name.empty? ? nil : name
end

def weak_data_name(line)
  code = line.lstrip
  if code.byteslice(0, WEAK_ATTR.bytesize) == WEAK_ATTR
    body = code.byteslice(WEAK_ATTR.bytesize, code.bytesize - WEAK_ATTR.bytesize).rstrip
    return nil if body.index('(') || body.index(')') || body.byteslice(body.bytesize - 1, 1) != ';'
    return trailing_ident(body.byteslice(0, body.bytesize - 1).rstrip)
  end
  at = code.index(' ' + WEAK_ATTR + ';')
  return trailing_ident(code.byteslice(0, at)) unless at.nil?
  # A weak reference to a symbol that may be absent (std tests for it at run time): `extern char __attribute__((weak))
  # NAME[0];`. The reference is weakened in the object as well, so the link leaves it unresolved (null) when absent.
  if code.byteslice(0, 7) == 'extern ' && code.index(' ' + WEAK_ATTR + ' ') && code.byteslice(code.bytesize - 4, 4) == '[0];'
    return trailing_ident(code.byteslice(0, code.bytesize - 4))
  end
  nil
end

# The name an `extern` declaration line declares: the identifier before its first '(', or nil.
def declared_name(line)
  open = line.index('(')
  return nil if open.nil?
  head = line.byteslice(0, open).rstrip
  i = head.bytesize
  i -= 1 while i > 0 && IDENT_CHARS.index(head.byteslice(i - 1, 1))
  name = head.byteslice(i, head.bytesize - i)
  name.empty? ? nil : name
end

# The label of an `asm("LABEL");` line, which must be exactly that form.
def asm_label(line)
  rest = line.byteslice(5, line.bytesize - 5)
  q = rest.index('"')
  fail_with("unsupported asm form (only asm(\"LABEL\"); after an extern function): #{line}") if q.nil? || rest.byteslice(q, rest.bytesize - q) != '");'
  rest.byteslice(0, q)
end

# Every occurrence of `from` in `s` replaced by `to`.
def replace_all(s, from, to)
  out = ''
  rest = s
  while (i = rest.index(from)) != nil
    out << rest.byteslice(0, i) << to
    rest = rest.byteslice(i + from.bytesize, rest.bytesize - i - from.bytesize)
  end
  out << rest
end

# mrustc writes a trailing comma in an attribute list, `__attribute__((__aligned__(16),))`. GNU C allows it, but
# qbe-prep matches the aligned attribute only without the comma, and drops it otherwise, which changes the
# layout (cproc then fails the alignment assertion next to the struct). The comma is removed on attribute lines
# only: `,)` also occurs in string literals.
def drop_attribute_trailing_comma(line)
  return line unless line.index('__attribute__((')
  replace_all(line, ',))', '))')
end

def rewrite_line(line)
  ATOMICLOOP_HEAD.each do |head, body|
    return body if line.byteslice(0, head.bytesize) == head
  end
  # Keyword and attribute forms first, so the statement-expression rewrites below see plain C types.
  line = replace_word(drop_attribute_trailing_comma(line), '_Atomic', '')
  # `__extension__` only silences pedantic warnings. glibc's `__restrict` is the C99 `restrict`, which cproc
  # reads (the `__` form is the GNU keyword, which it does not).
  line = replace_word(line, '__extension__', '')
  line = replace_word(line, '__restrict__', 'restrict')
  line = replace_word(line, '__restrict', 'restrict')
  # glibc's redirect of strerror_r to the XPG symbol. libcore only declares strerror_r, so the label is dropped.
  line = replace_all(line, ' __asm__ ("" "__xpg_strerror_r")', '')
  # GNU's name for the function in the message of an assert form; C99's `__func__` in cproc.
  line = replace_word(line, '__PRETTY_FUNCTION__', '__func__')
  line = rewrite_assert_stmt_exprs(line) if line.index(ASSERT_IF)
  line = rewrite_atomic_stmt_exprs(line) if line.index(ATOMIC_HEAD)
  line
end

# Inline asm, by its statement (stripped of indentation), and the C that does the same. The operand names differ from
# one crate to the next, so each form is taken apart by its fixed text and the names are kept. `pause` is a spin-loop
# hint with no effect on data. xgetbv and cpuid read CPU state, so they call helpers of the tail assembly.
# take_seq: the captures of `text` between `prefix`, the separators in `seps` and `suffix`, or nil when it does not fit.
def take_seq(text, prefix, seps, suffix)
  return nil unless text.byteslice(0, prefix.bytesize) == prefix
  return nil unless text.byteslice(text.bytesize - suffix.bytesize, suffix.bytesize) == suffix
  pos = prefix.bytesize
  end_i = text.bytesize - suffix.bytesize
  caps = []
  seps.each do |sep|
    i = text.index(sep, pos)
    return nil if i.nil? || i + sep.bytesize > end_i
    caps << text.byteslice(pos, i - pos).strip
    pos = i + sep.bytesize
  end
  return nil if pos > end_i
  caps << text.byteslice(pos, end_i - pos).strip
  caps
end

def asm_rewrite(code)
  return ';' if code == '__asm__ __volatile__ ("pause");'
  # An empty template that only takes a value in and out of a register (`hint::black_box`, constant_time_eq's and
  # blake3's optimisation barrier): it stops the C compiler from reasoning about the value, which QBE does not do.
  ['"+r" (', '"+q" ('].each do |cls|
    return ';' unless take_seq(code, '__asm__ __volatile__(".intel_syntax noprefix; /* %0 */;\n .att_syntax; " : ' + cls, [], ') ::);').nil?
  end
  # A prefetch is a cache hint with no effect on data (mold's `prefetch`).
  return ';' unless take_seq(code, '__asm__ __volatile__(".intel_syntax noprefix; prefetcht0 [%0];\n .att_syntax; " : : "r" (', [], '): "memory");').nil?
  x = take_seq(code, '__asm__ __volatile__ ("xgetbv" : "=a" (', ['), "=d" (', ') : "c" ('], ') );')
  unless x.nil?
    lo, hi, arg = x
    return "{ unsigned long __nfcxx_xgv = __nfcxx_xgetbv (#{arg}); #{lo} = (unsigned int)__nfcxx_xgv; #{hi} = (unsigned int)(__nfcxx_xgv >> 32); }"
  end
  c = take_seq(code, '__asm__("cpuid" : "=a" (', ['), "=b" (', '), "=c" (', '), "=d" (', ') : "a" (', '), "c" ('], ') );')
  unless c.nil?
    v0, v1, v2, v3, a0, a1 = c
    return "{ unsigned int __nfcxx_regs[4]; __nfcxx_cpuid (#{a0}, #{a1}, __nfcxx_regs); #{v0} = __nfcxx_regs[0]; " \
           "#{v1} = __nfcxx_regs[1]; #{v2} = __nfcxx_regs[2]; #{v3} = __nfcxx_regs[3]; }"
  end
  nil
end
# ---- General inline asm: outlined into a helper that the host C compiler builds -------------------------------------
# cproc has no inline asm. An asm statement that the rewrites above do not know (portable-atomic's cmpxchg16b loops
# and `lock bt*`, `lock neg`) moves, unchanged, into a function of a C file that scripts/mrustc-nfcc.sh compiles with
# the host cc and links into the crate's tail object. The function takes a pointer to each variable the operands name,
# declares the variable again (with its `register ... asm("REG")` binding when it had one), runs the asm, and stores
# the variables back. The statement becomes a call that passes their addresses. Only operands that are variables of
# scalar or pointer type are outlined; another statement is left for cproc to refuse. The helpers are weak, named by a
# hash of their text, so crates with the same statement share one.

# Scalar types a helper can declare (pointer types are declared `void *`; their width is all an `"r"` operand sees).
ASM_SCALARS = %w[uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t uintptr_t intptr_t size_t
                 RUST_BOOL RUST_CHAR float double]
ASM_HELPER_PRELUDE = "#include <stdint.h>\n#include <stddef.h>\ntypedef uint8_t RUST_BOOL;\ntypedef uint32_t RUST_CHAR;\n"

# The type of a declaration line ` TYPE NAME;` (or `  TYPE NAME,` / `  TYPE NAME` in a parameter list), as
# [name, type], or nil.
def asm_decl(line)
  s = line.strip
  s = s.byteslice(0, s.bytesize - 1).rstrip if s.end_with?(';') || s.end_with?(',')
  return nil if s.empty? || s.index('(') || s.index('=') || s.index('[') || s.index('{') || s.index('"')
  name = trailing_ident(s)
  return nil if name.nil? || name.bytesize == s.bytesize
  type = s.byteslice(0, s.bytesize - name.bytesize).strip
  return nil if type.empty? || type.start_with?('return') || type.start_with?('goto')
  [name, type]
end

# A block-local ` T NAME = INIT;` with T a scalar or pointer type (mrustc's `uintptr_t asm_anon_0 = 0;`), as
# [name, type], or nil. Assignments (` var5 = ...;`, ` x._0 = ...;`) have no type before the name.
def asm_decl_init(line)
  s = line.strip
  eq = s.index(' = ')
  return nil if eq.nil? || !s.end_with?(';')
  d = asm_decl(s.byteslice(0, eq) + ';')
  return nil if d.nil? || asm_helper_type(d[1]).nil? || d[1].index('.') || d[1].start_with?('*')
  d
end

# ` register T NAME asm("REG") = INIT;` as [T, NAME, REG, INIT], or nil.
def asm_register_decl(code)
  return nil unless code.start_with?('register ') && code.end_with?(';')
  at = code.index(' asm("')
  return nil if at.nil?
  q = code.index('")', at + 6)
  return nil if q.nil?
  head = code.byteslice(9, at - 9).strip
  name = trailing_ident(head)
  return nil if name.nil?
  type = head.byteslice(0, head.bytesize - name.bytesize).strip
  reg = code.byteslice(at + 6, q - at - 6)
  rest = code.byteslice(q + 2, code.bytesize - q - 2).strip
  init = nil
  if rest.start_with?('=')
    init = rest.byteslice(1, rest.bytesize - 2).strip
  elsif rest != ';'
    return nil
  end
  [type, name, reg, init]
end

# The type a helper declares a variable with, or nil when it cannot.
def asm_helper_type(type)
  return 'void *' if type.end_with?('*')
  ASM_SCALARS.include?(type) ? type : nil
end

# The operand expressions of an asm statement `__asm__ __volatile__(TEMPLATE : OUTS : INS : CLOBBERS);`, or nil when
# it is not of that form. Strings are skipped, so ':' ',' '(' ')' in the template or in constraints do not count.
def asm_operands(code)
  start = code.index('__asm__')
  return nil if start.nil? || start != 0
  open = code.index('(')
  return nil if open.nil?
  head = code.byteslice(7, open - 7).strip
  return nil unless head == '' || head == '__volatile__' || head == 'volatile'
  return nil unless code.end_with?(');')
  body = code.byteslice(open + 1, code.bytesize - open - 3)
  sections = [[]]
  cur = ''
  depth = 0
  i = 0
  n = body.bytesize
  while i < n
    c = body.byteslice(i, 1)
    if c == '"'
      j = i + 1
      while j < n
        d = body.byteslice(j, 1)
        if d == '\\'
          j += 2
          next
        end
        break if d == '"'
        j += 1
      end
      return nil if j >= n
      cur << body.byteslice(i, j - i + 1)
      i = j + 1
      next
    end
    if c == '(' then depth += 1
    elsif c == ')' then depth -= 1
    end
    if depth == 0 && (c == ':' || c == ',')
      sections.last << cur.strip
      cur = ''
      sections << [] if c == ':'
    else
      cur << c
    end
    i += 1
  end
  return nil if depth != 0
  sections.last << cur.strip
  return nil if sections.size < 2 || sections.size > 4   # no `asm goto` labels
  exprs = []
  sections[1..2].to_a.each do |sec|
    sec.each do |op|
      next if op.empty?
      return nil unless op.start_with?('"') || op.start_with?('[')
      a = op.index('(')
      return nil if a.nil? || !op.end_with?(')')
      e = op.byteslice(a + 1, op.bytesize - a - 2).strip
      return nil if e.empty? || trailing_ident(e) != e || '0123456789'.index(e.byteslice(0, 1))
      exprs << e unless exprs.include?(e)
    end
  end
  exprs
end

# FNV-1a of a string, as 8 hex digits.
def asm_hash(s)
  h = 2166136261
  s.each_byte { |b| h = ((h ^ b) * 16777619) & 0xffffffff }
  r = h.to_s(16)
  '0' * (8 - r.bytesize) + r
end

# The call that replaces asm statement `code`, and the helper's definition, as [call, helper name, definition], or nil.
# `types` maps a variable to its C type, `regs` a register variable to its register.
def asm_outline(code, types, regs)
  vars = asm_operands(code)
  return nil if vars.nil? || vars.empty?
  params = []
  decls = []
  backs = []
  vars.each_with_index do |v, k|
    t = types[v]
    return nil if t.nil?
    ht = asm_helper_type(t)
    return nil if ht.nil?
    params << "#{ht} *__nfcxx_p#{k}"
    if regs.key?(v)
      decls << "\tregister #{ht} #{v} asm(\"#{regs[v]}\") = *__nfcxx_p#{k};"
    else
      decls << "\t#{ht} #{v} = *__nfcxx_p#{k};"
    end
    backs << "\t*__nfcxx_p#{k} = #{v};"
  end
  text = "(#{params.join(', ')})\n{\n#{decls.join("\n")}\n\t#{code}\n#{backs.join("\n")}\n}\n"
  name = "__nfcxx_asm_#{asm_hash(text)}"
  defn = "__attribute__((weak)) void #{name}#{text}"
  call = "#{name}(#{vars.map { |v| '&' + v }.join(', ')});"
  [call, name, defn, vars.size]
end

# The helpers those rewrites call, declared at the top of the output (before the prelude's typedefs, so plain types).
ASM_HELPER_DECLS = [
  'extern unsigned long __nfcxx_xgetbv (unsigned int);',
  'extern void __nfcxx_cpuid (unsigned int, unsigned int, unsigned int *);'
]
# Their definitions in the tail (x86-64, System V calling convention; weak, so each object may carry them).
ASM_HELPER_TAIL = <<'TAIL'
.weak __nfcxx_xgetbv
.type __nfcxx_xgetbv,@function
__nfcxx_xgetbv:
	mov %edi, %ecx
	xgetbv
	shl $32, %rdx
	or %rdx, %rax
	ret
.weak __nfcxx_cpuid
.type __nfcxx_cpuid,@function
__nfcxx_cpuid:
	push %rbx
	mov %rdx, %r8
	mov %edi, %eax
	mov %esi, %ecx
	cpuid
	mov %eax, (%r8)
	mov %ebx, 4(%r8)
	mov %ecx, 8(%r8)
	mov %edx, 12(%r8)
	pop %rbx
	ret
TAIL

# glibc runs the function pointers in `.init_array.N` sections at start-up. mrustc puts one there for std's argv
# capture: `__attribute__((section(".init_array.N"))) union {...} NAME;`, initialised with `(uintptr_t)&FUNC`.
# cproc accepts the section attribute on functions only, so the attribute is dropped, and the tail places the
# address of FUNC in that section. Only that shape is handled; another section stops the rewrite.
SECTION_ATTR = '__attribute__((section("'

# [section, rest of the line without the attribute] when the line carries an init_array section attribute, else nil.
def init_array_section(line)
  at = line.index(SECTION_ATTR)
  return nil if at.nil?
  start = at + SECTION_ATTR.bytesize
  q = line.index('"', start)
  close = q.nil? ? nil : line.index(')))', q)
  fail_with("unsupported section attribute: #{line}") if close.nil?
  section = line.byteslice(start, q - start)
  fail_with("only .init_array sections are handled: #{line}") unless section.byteslice(0, 12) == '.init_array.'
  [section, line.byteslice(0, at) + line.byteslice(close + 3, line.bytesize - close - 3)]
end

# The function of an initialiser `NAME = { .raw = {(uintptr_t)&FUNC} };`, or nil for another line.
INIT_ARRAY_INIT = ' = { .raw = {(uintptr_t)&'
def init_array_init(line)
  at = line.index(INIT_ARRAY_INIT)
  return nil if at.nil?
  name = trailing_ident(line.byteslice(0, at))
  rest = line.byteslice(at + INIT_ARRAY_INIT.bytesize, line.bytesize - at - INIT_ARRAY_INIT.bytesize)
  close = rest.index('}')
  fail_with("unsupported initialiser: #{line}") if close.nil?
  [name, rest.byteslice(0, close).strip]
end

# `extern T NAME asm("LABEL");` on one line: a data object named by an asm label. cproc has no asm labels, and the
# label names a symbol, so NAME is replaced by LABEL everywhere in the file and the label leaves the declaration.
# (Functions with labels are handled by asm_label, below.)
def data_asm_label(line)
  at = line.index(' asm("')
  return nil if at.nil? || line.byteslice(0, 7) != 'extern '
  rest = line.byteslice(at + 6, line.bytesize - at - 6)
  q = rest.index('"')
  fail_with("unsupported asm label on a declaration: #{line}") if q.nil? || rest.byteslice(q, rest.bytesize - q) != '")' && rest.byteslice(q, rest.bytesize - q) != '");'
  [trailing_ident(line.byteslice(0, at)), rest.byteslice(0, q)]
end

def main(argv)
  if argv.size != 4 && argv.size != 5
    $stderr.puts "usage: scripts/mrb scripts/mrustc-prep.rb in.c out.c tail.s weak.txt [asm.c]"
    exit 2
  end
  src = File.open(argv[0], 'rb') { |f| f.read } || ''
  out = ASM_HELPER_DECLS.dup
  labels = []   # [declared name, asm label] pairs, in order
  weak = []     # data symbols mrustc marks weak (see weak_data_name)
  name = nil    # the extern function the last declaration line declared
  packed = false  # inside a `#pragma pack(push, 1)` region
  init_pending = {}   # init_array object name -> its section, until its initialiser is seen
  init_entries = []   # [section, function] pairs
  asm_types = {}      # variable -> its C type, from the declarations seen so far (see asm_outline)
  asm_regs = {}       # register variable -> its register
  asm_protos = []     # prototypes of the outlined asm helpers
  asm_defs = {}       # helper name -> definition
  # Data objects named by an asm label (see data_asm_label): renamed throughout the file, before the rewrite below.
  lines = src.split("\n", -1)
  renames = {}
  lines.each { |l| r = data_asm_label(l); renames[r[0]] = r[1] unless r.nil? }
  unless renames.empty?
    lines = lines.map do |l|
      r = data_asm_label(l)
      l = replace_all(l, ' asm("' + r[1] + '")', '') unless r.nil?
      renames.each { |n, label| l = replace_word(l, n, label) }
      l
    end
  end
  lines.each do |line|
    sec = init_array_section(line)
    unless sec.nil?
      line = sec[1]
      decl = line.rstrip
      decl = decl.byteslice(0, decl.bytesize - 1).rstrip if decl.byteslice(decl.bytesize - 1, 1) == ';'
      init_pending[trailing_ident(decl)] = sec[0]
    end
    ini = init_array_init(line)
    init_entries << [init_pending.delete(ini[0]), ini[1]] if !ini.nil? && init_pending.key?(ini[0])
    wn = weak_data_name(line)
    weak << wn unless wn.nil?
    name = declared_name(line) if line.byteslice(0, 7) == "extern "
    code = line.lstrip
    if code.byteslice(0, 5) == 'asm("'
      fail_with("asm label with no extern function before it: #{line}") if name.nil?
      labels << [name, asm_label(code)]
      out << ';'   # the declaration keeps its ';'
      next
    end
    d = asm_decl(line) || asm_decl_init(line)
    asm_types[d[0]] = d[1] unless d.nil?
    rd = asm_register_decl(code)
    unless rd.nil?
      # A register variable of an asm block: a plain local here (cproc has no register bindings, and the helper takes
      # its address); the helper binds it to its register again.
      t, n, reg, init = rd
      asm_types[n] = t
      asm_regs[n] = reg
      line = " #{t} #{n}" + (init.nil? ? '' : " = #{init}") + ';'
    end
    asm = asm_rewrite(code)
    if asm.nil? && code.start_with?('__asm__')
      o = asm_outline(code, asm_types, asm_regs)
      unless o.nil?
        call, hname, defn, nargs = o
        unless asm_defs.key?(hname)
          asm_defs[hname] = defn
          asm_protos << "extern void #{hname}(#{(['void *'] * nargs).join(', ')});"
        end
        asm = ' ' + call
      end
    end
    line = asm unless asm.nil?
    line += "\n" + WIDE_ATOMIC_HELPERS if line == WIDE_ATOMIC_TYPEDEF
    # cproc ignores #pragma, so the struct in a packed region gets the attribute after its keyword, where cproc
    # reads it (`struct __attribute__((packed)) tag {`; after the closing brace it is refused).
    if line == '#pragma pack(push, 1)'
      packed = true
    elsif line == '#pragma pack(pop)'
      packed = false
    elsif line.byteslice(0, 13) == '#pragma pack(' && line != '#pragma pack(push, 1)'
      fail_with("unsupported pack pragma (only push, 1 and pop): #{line}")
    elsif packed && line.byteslice(0, 7) == 'struct ' && line.byteslice(line.bytesize - 2, 2) == ' {'
      line = 'struct __attribute__((packed)) ' + line.byteslice(7, line.bytesize - 7)
    end
    out << rewrite_line(line)
  end
  tail = ''
  versioned = 0
  labels.each do |n, label|
    # A versioned label (`cfgetispeed@GLIBC_2.2.5`, libc 0.2.189) is not a symbol name in an instruction: the jump goes to
    # a local alias that `.symver` binds to that version.
    target = label
    if label.index('@')
      target = "__nfcxx_versioned_#{versioned}"
      versioned += 1
      tail << ".symver #{target}, #{label}\n"
    end
    # The target is weak too: a label whose symbol is absent (sysctl, on glibc 2.32 and later) only matters if it is called.
    tail << ".weak #{target}\n.weak #{n}\n.type #{n},@function\n#{n}:\n\tjmp #{target}@PLT\n"
  end
  fail_with("init_array object without its initialiser: #{init_pending.keys.join(' ')}") unless init_pending.empty?
  init_entries.each do |sec, f|
    tail << ".section #{sec},\"aw\"\n.p2align 3\n.quad #{f}\n"
  end
  tail << ".text\n"
  File.open(argv[3], "wb") { |f| f.write(weak.map { |n| n + "\n" }.join) }
  tail << ASM_HELPER_TAIL
  out = out[0, ASM_HELPER_DECLS.size] + asm_protos + out[ASM_HELPER_DECLS.size, out.size - ASM_HELPER_DECLS.size] unless asm_protos.empty?
  File.open(argv[1], 'wb') { |f| f.write(out.join("\n")) }
  unless argv[4].nil?
    File.open(argv[4], 'wb') { |f| f.write(asm_defs.empty? ? '' : ASM_HELPER_PRELUDE + asm_defs.values.join("\n")) }
  end
  fail_with("inline asm outlined but no asm.c output given") if argv[4].nil? && !asm_defs.empty?
  # A non-executable stack for the object (without the note, ld makes the program's stack executable).
  tail << ".section .note.GNU-stack,\"\",@progbits\n"
  File.open(argv[2], 'wb') { |f| f.write(tail) }
end

main(ARGV)
