# Local lifetime analysis for annotated Path B IR. Run with scripts/mrb.
# Exit 0: supported local checks passed; 1: lifetime error; 2: malformed IR;
# 3: unsupported analysis. This is not full Rust or C++ borrow checking.
class BadIR < StandardError; end
class BorrowRefused < StandardError; end

# Reader follows pathb-qbe-emit.rb, including quoted sigils and octal escapes.
class IRStr
  attr_reader :codes

  def initialize(codes)
    @codes = codes
  end

  def to_s
    s = "".b
    @codes.each { |c| s << (c & 255).chr }
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

# str.isspace() for a latin-1 character
def space_byte?(c)
  (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0x85 || c == 0xa0
end

def read_string(text, i)
  out = []
  i += 1
  n = text.bytesize
  while true
    raise BadIR, "unterminated string in IR" if i >= n
    c = text.getbyte(i)
    if c == 34
      return [out, i + 1]
    end
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

def octal?(c)
  c >= 48 && c <= 55
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


def bh(x)
  x.is_a?(Array) ? x[0] : nil
end

def borrow_scalar_type!(ty)
  return if bh(ty) == 'ptr'
  scalars = %w[bool char signed_char unsigned_char short unsigned_short int unsigned_int long unsigned_long long_long unsigned_long_long float double]
  raise BorrowRefused, 'aggregate/unsupported values need field-sensitive provenance' unless scalars.include?(ty)
end

def bname(x)
  x.is_a?(IRStr) ? x.to_s : x
end

class LocalLifetime
  attr_reader :errors

  def initialize(f)
    raise BadIR, 'function header' unless f.length >= 4 && bh(f[2]) == 'ret' && bh(f[3]) == 'params'
    @name = bname(f[1])
    @slots = {}
    @params = []
    @nodes = []
    @labels = {}
    @errors = []
    @report = false
    @declared = {}
    scan = lambda do |x|
      return unless x.is_a?(Array)
      if bh(x) == 'decl' && x[1].is_a?(IRSym) && x[1].sig == '$'
        @declared[x[1].name] = true
      end
      x.each { |y| scan.call(y) }
    end
    scan.call(f)
    raise BorrowRefused, 'no local declaration facts; use NFCXX_PATHB_BORROW=1' if @declared.empty?
    f.drop(4).each do |x|
      if bh(x) == 'slot'
        raise BadIR, 'slot form' unless x.length == 5
        borrow_scalar_type!(x[2])
        @slots[bname(x[1])] = true
      end
    end
    f[3].drop(1).each do |p|
      raise BadIR, 'param form' unless bh(p) == 'param'
      @params << [p[1], bname(p[2]), bh(p[3]) == 'ptr']
    end
    @slots.each_key do |name|
      unless @declared[name] || @params.any? { |p| p[1] == name }
        raise BorrowRefused, "missing declaration facts for slot #{name}"
      end
    end
    body = f.drop(4).reject { |x| ['slot', 'static', 'weak'].include?(bh(x)) }
    @entry = sequence(body, node(['join'], []), nil, nil)
    @nodes.each do |n|
      n[1].map! do |edge|
        if edge.is_a?(String)
          raise BadIR, "unknown label #{edge}" unless @labels.key?(edge)
          @labels[edge]
        else
          edge
        end
      end
    end
  end

  def node(x, edges)
    id = @nodes.length
    @nodes << [x, edges.compact]
    id
  end

  # Build one node per statement. Reverse construction preserves fallthrough,
  # while labels and loop targets make backward edges explicit.
  def sequence(xs, follow, brk, cont)
    xs.reverse_each do |x|
      h = bh(x)
      case h
      when 'block', 'then', 'else', 'body', 'step'
        follow = sequence(x.drop(1), follow, brk, cont)
      when 'if'
        raise BadIR, 'if form' unless bh(x[2]) == 'then' && (x[3].nil? || bh(x[3]) == 'else')
        a = sequence(x[2].drop(1), follow, brk, cont)
        b = x[3] ? sequence(x[3].drop(1), follow, brk, cont) : follow
        follow = node(['condition', x[1]], [a, b])
      when 'loop'
        raise BadIR, 'loop form' unless x.drop(1).all? { |p| ['body', 'step'].include?(bh(p)) }
        header = node(['join'], [])
        step = x.find { |p| bh(p) == 'step' }
        body = x.find { |p| bh(p) == 'body' }
        step_entry = sequence(step ? step.drop(1) : [], header, follow, header)
        entry = sequence(body ? body.drop(1) : [], step_entry, follow, step_entry)
        @nodes[header][1] = [entry]
        follow = header
      when 'break', 'continue'
        target = h == 'break' ? brk : cont
        raise BorrowRefused, "#{h} without a supported enclosing loop" if target.nil?
        follow = node(['join'], [target])
      when 'label'
        label = bname(x[1])
        raise BadIR, "duplicate label #{label}" if @labels.key?(label)
        follow = node(['join'], [follow])
        @labels[label] = follow
      when 'goto'
        follow = node(['join'], [bname(x[1])])
      when 'return', 'unreachable'
        follow = node(x, [])
      else
        follow = node(x, [follow])
      end
    end
    follow
  end

  def diagnostic(code, place)
    msg = "#{@name}: #{code}: #{place}"
    @errors << msg if @report && !@errors.include?(msg)
  end

  def key(x)
    if x.is_a?(IRSym)
      return 'slot:' + x.name if x.sig == '$'
      return nil if x.sig == '@' || x.sig == '&'
    end
    return x if x.is_a?(String) && x.start_with?('%')
    raise BorrowRefused, 'unsupported place'
  end

  # Each storage state is a set: dead, uninitialized, initialized. Pointer
  # provenance is a set of local storage identities, or external/unknown.
  def access(place, state, read)
    return if place == 'external'
    if place.start_with?('ended:')
      diagnostic('use-after-scope', place[6..-1])
      return
    end
    raise BorrowRefused, 'unknown pointer provenance' if place == 'unknown'
    status = state['life:' + place] || ['dead']
    diagnostic('use-after-scope', place) if status.include?('dead')
    diagnostic('uninitialized', place) if read && status.include?('uninitialized')
  end

  def value(x, state)
    if x.is_a?(IRSym)
      return [x.name] if x.sig == '$'
      return ['external']
    end
    if x.is_a?(String)
      return state['value:' + x] || ['unknown'] if x.start_with?('%')
      return []
    end
    raise BadIR, 'operand form' unless x.is_a?(Array)
    case bh(x)
    when 'const'
      borrow_scalar_type!(x[1])
      bh(x[1]) == 'ptr' ? ['unknown'] : []
    when 'load'
      borrow_scalar_type!(x[1])
      places = value(x[2], state)
      places.each { |p| access(p, state, true) }
      if bh(x[1]) == 'ptr'
        places.flat_map { |p| state['pointer:' + p] || ['unknown'] }.uniq
      else
        []
      end
    when 'bitcast'
      v = value(x[2], state)
      raise BorrowRefused, 'pointer cast without provenance' if bh(x[1]) == 'ptr' && v.empty?
      raise BorrowRefused, 'pointer-to-integer cast' if bh(x[1]) != 'ptr' && !v.empty?
      v
    when 'call'
      raise BorrowRefused, 'calls require lifetime/effect contracts'
    else
      # Arithmetic on addresses would erase provenance. Restrict this first
      # increment to scalar arithmetic and conversions on non-pointer values.
      allowed = %w[wadd wsub wmul cadd csub cmul cdiv crem cshl cshr and or xor eq ne lt.s lt.u le.s le.u gt.s gt.u ge.s ge.u iconv]
      raise BorrowRefused, "expression #{bh(x)}" unless allowed.include?(bh(x))
      raise BorrowRefused, 'pointer conversion requires provenance' if bh(x[1]) == 'ptr'
      vals = x.drop(2).flat_map { |v| value(v, state) }
      raise BorrowRefused, 'pointer arithmetic/conversion requires place projections' unless vals.empty?
      []
    end
  end

  def transfer(x, state)
    arities = {'join'=>[1], 'unreachable'=>[1], 'decl'=>[3], 'scope-end'=>[2],
               'let'=>[4], 'set'=>[4], 'store'=>[4], 'return'=>[1,2],
               'condition'=>[2], 'eval'=>[2], 'nonnull'=>[2], 'rref-arg'=>[2]}
    sizes = arities[bh(x)]
    raise BadIR, "#{bh(x)} form" if sizes && !sizes.include?(x.length)
    case bh(x)
    when 'join', 'unreachable', 'loc'
      # Locations are preserved in input; diagnostics currently identify functions and slots.
    when 'decl'
      raise BadIR, 'decl form' unless x.length == 3 && %w[val ref param temp].include?(x[2])
      k = key(x[1])
      if k && k.start_with?('slot:')
        name = k[5..-1]
        raise BadIR, "undeclared slot #{name}" unless @slots[name]
        state['life:' + name] = ['uninitialized']
        state['pointer:' + name] = ['unknown']
      end
    when 'scope-end'
      k = key(x[1])
      raise BadIR, 'scope-end requires a local slot' unless k && k.start_with?('slot:')
      name = k[5..-1]
      state['life:' + name] = ['dead']
      # Keep old pointers invalid even if the same slot is declared again on a
      # later loop iteration. Storage identity alone must not revive a loan.
      state.keys.each do |entry|
        if entry.start_with?('value:') || entry.start_with?('pointer:')
          state[entry] = state[entry].map { |p| p == name ? 'ended:' + name : p }.uniq
        end
      end
    when 'let', 'set'
      borrow_scalar_type!(x[2])
      v = value(x[3], state)
      raise BadIR, 'register destination' unless x[1].is_a?(String) && x[1].start_with?('%')
      state['value:' + x[1]] = v
    when 'store'
      borrow_scalar_type!(x[1])
      v = value(x[3], state)
      dest = value(x[2], state)
      dest.each { |p| access(p, state, false) }
      raise BorrowRefused, 'store through external storage may escape a local address' if dest.include?('external')
      raise BorrowRefused, 'store through an aliased destination' unless dest.length == 1
      p = dest[0]
      return state if p.start_with?('ended:')
      # A store cannot resurrect storage after scope-end.
      old = state['life:' + p] || ['dead']
      state['life:' + p] = old.map { |s| s == 'dead' ? s : 'initialized' }.uniq
      state['pointer:' + p] = v
    when 'return'
      refs = x[1] ? value(x[1], state) : []
      raise BorrowRefused, 'return with unknown pointer provenance' if refs.include?('unknown')
      refs.each { |p| diagnostic('return-local-address', p.start_with?('ended:') ? p[6..-1] : p) unless p == 'external' }
    when 'condition', 'eval', 'nonnull'
      value(x[1], state)
    when 'rref-arg'
      raise BorrowRefused, 'rvalue-reference arguments require language-specific move contracts'
    else
      raise BorrowRefused, "statement #{bh(x)}"
    end
    state
  end

  def run
    return if @entry.nil?
    initial = {}
    @slots.each_key { |s| initial['life:' + s] = ['dead']; initial['pointer:' + s] = ['unknown'] }
    @params.each do |p, name, pointer|
      initial['value:' + p] = pointer ? ['external'] : []
      initial['life:' + name] = ['uninitialized'] if @slots[name]
    end
    incoming = { @entry => initial }
    queue = [@entry]
    until queue.empty?
      id = queue.shift
      out = transfer(@nodes[id][0], incoming[id].dup)
      @nodes[id][1].each do |succ|
        old = incoming[succ]
        merged = out.dup
        if old
          (old.keys + out.keys).uniq.each do |k|
            # Missing register definitions cannot acquire provenance from just
            # one predecessor. Slot entries exist on every path.
            a = old[k] || ['unknown']
            b = out[k] || ['unknown']
            merged[k] = (a + b).uniq.sort
          end
        end
        if old != merged
          incoming[succ] = merged
          queue << succ unless queue.include?(succ)
        end
      end
    end
    @report = true
    incoming.each { |id, s| transfer(@nodes[id][0], s.dup) }
  end
end

begin
  raise BadIR, 'usage: scripts/mrb scripts/pathb-borrowck.rb FILE.ir' unless ARGV.length == 1
  forms = parse_forms(tokenize(File.read(ARGV[0])))
  raise BadIR, 'missing ir-module' unless bh(forms[0]) == 'ir-module'
  functions = forms.select { |f| bh(f) == 'function' }
  raise BorrowRefused, 'no functions to analyze' if functions.empty?
  errors = []
  functions.each do |f|
    checker = LocalLifetime.new(f)
    checker.run
    errors.concat(checker.errors)
  end
  if errors.empty?
    puts 'ok: local lifetime checks passed (supported subset only)'
  else
    errors.each { |e| puts e }
    exit 1
  end
rescue BorrowRefused => e
  $stderr.puts "refused: #{e.message}"
  exit 3
rescue BadIR => e
  $stderr.puts "error: #{e.message}"
  exit 2
end
