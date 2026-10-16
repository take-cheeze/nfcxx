# Rewrite the C that mrustc's C backend emits so cproc accepts it. Run on the output of `cc -E` (the system
# headers it includes are expanded there), before scripts/qbe-cc, which then does the rest (qbe-prep.rb, cproc,
# QBE, assembling). scripts/mrustc-nfcc.sh does all of it. The forms rewritten, the rest passes through unchanged:
#
#   * `_Atomic` type qualifier, from <stdatomic.h> (`typedef _Atomic char atomic_char`). cproc has no qualifier,
#     so it is dropped, as scripts/strip-atomic.py drops it for libc++. The atomicity of Rust's atomics comes from
#     the calls in the next form, not from the qualifier.
#   * `__mrustc_atomicloop{8,16,32,64}`, mrustc's fetch-op loop (a compare-exchange retry loop, one line of the
#     prelude). It uses GCC's generic `__atomic_load` and `__atomic_compare_exchange` in statement expressions,
#     which cproc does not parse. Each line becomes the same loop over the sized `__atomic_load_N` and
#     `__atomic_compare_exchange_N`, which qbe-prep.rb declares and the link takes from libatomic (as gcc does).
#   * An extern function whose symbol is named by an asm label: `extern T ZRG...(...)` then `asm("__rust_alloc");`.
#     cproc has no asm labels, so the label is dropped from the C, and the tail assembly (the third argument)
#     defines the mangled name as a jump to the label: `ZRG...: jmp __rust_alloc@PLT`. Only functions are handled;
#     a label on anything else stops the rewrite. ELF only: the tail assumes no leading underscore on symbols.
#
# The script uses no regular expressions, so it runs on the self-built mruby (scripts/mrb), as qbe-prep.rb does.
# Usage: scripts/mrb scripts/mrustc-prep.rb in.c out.c tail.s

IDENT_CHARS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'

def fail_with(msg)
  $stderr.puts "mrustc-prep: #{msg}"
  exit 1
end

# Drop each `_Atomic ` that starts a token (not the tail of a longer identifier).
def strip_atomic(line)
  out = ''
  rest = line
  while (i = rest.index('_Atomic ')) != nil
    prev = i > 0 ? rest.byteslice(i - 1, 1) : ' '
    if IDENT_CHARS.index(prev)
      out << rest.byteslice(0, i + 8)
    else
      out << rest.byteslice(0, i)
    end
    rest = rest.byteslice(i + 8, rest.bytesize - i - 8)
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

def rewrite_line(line)
  ATOMICLOOP_HEAD.each do |head, body|
    return body if line.byteslice(0, head.bytesize) == head
  end
  strip_atomic(line)
end

def main(argv)
  if argv.size != 3
    $stderr.puts "usage: scripts/mrb scripts/mrustc-prep.rb in.c out.c tail.s"
    exit 2
  end
  src = File.open(argv[0], 'rb') { |f| f.read } || ''
  out = []
  labels = []   # [declared name, asm label] pairs, in order
  name = nil    # the extern function the last declaration line declared
  src.split("\n", -1).each do |line|
    name = declared_name(line) if line.byteslice(0, 7) == "extern "
    code = line.lstrip
    if code.byteslice(0, 5) == 'asm("'
      fail_with("asm label with no extern function before it: #{line}") if name.nil?
      labels << [name, asm_label(code)]
      out << ';'   # the declaration keeps its ';'
      next
    end
    out << rewrite_line(line)
  end
  tail = ''
  labels.each do |n, label|
    tail << ".globl #{n}\n.type #{n},@function\n#{n}:\n\tjmp #{label}@PLT\n"
  end
  File.open(argv[1], 'wb') { |f| f.write(out.join("\n")) }
  # A non-executable stack for the object (without the note, ld makes the program's stack executable).
  tail << ".section .note.GNU-stack,\"\",@progbits\n" unless labels.empty?
  File.open(argv[2], 'wb') { |f| f.write(tail) }
end

main(ARGV)
