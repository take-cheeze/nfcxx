# Local lifetime analysis for annotated Path B IR. Run with scripts/mrb.
# --infer-loan-ends enables conservative last-use inference; default uses explicit ends.
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

  def initialize(f, infer_loan_ends = false)
    @infer_loan_ends = infer_loan_ends
    raise BadIR, 'function header' unless f.length >= 4 && bh(f[2]) == 'ret' && bh(f[3]) == 'params'
    @name = bname(f[1])
    @slots = {}
    @slot_info = {}
    @views = []
    @view_ids = {}
    @params = []
    @nodes = []
    @labels = {}
    @errors = []
    @report = false
    @declared = {}
    @loans = {}
    scan = lambda do |x|
      return unless x.is_a?(Array)
      if bh(x) == 'decl' && x[1].is_a?(IRSym) && x[1].sig == '$'
        @declared[x[1].name] = true
      end
      if bh(x) == 'borrow'
        raise BadIR, 'borrow form' unless x.length == 5 && bh(x[1]) == 'ptr' && x[2].is_a?(IRStr) && %w[shared exclusive].include?(x[3])
        id = bname(x[2])
        raise BadIR, "duplicate loan #{id}" if @loans.key?(id)
        place = direct_place(x[4])
        raise BorrowRefused, 'borrow requires a direct local place or constant field offset; use reborrow with an explicit parent' unless place
        @loans[id] = [place[0], x[3], nil, place[1], x[1][1]]
      end
      if bh(x) == 'reborrow'
        raise BadIR, 'reborrow form' unless x.length == 6 && bh(x[1]) == 'ptr' && x[2].is_a?(IRStr) && x[4].is_a?(IRStr) && %w[shared exclusive].include?(x[3])
        id = bname(x[2])
        raise BadIR, "duplicate loan #{id}" if @loans.key?(id)
        @loans[id] = [nil, x[3], bname(x[4]), expression_offset(x[5]), x[1][1]]
      end
      x.each { |y| scan.call(y) }
    end
    scan.call(f)
    raise BorrowRefused, 'no local declaration facts; use NFCXX_PATHB_BORROW=1' if @declared.empty?
    f.drop(4).each do |x|
      if bh(x) == 'slot'
        raise BadIR, 'slot form' unless x.length == 5
        borrow_scalar_type!(x[2]) unless %w[struct union array].include?(bh(x[2]))
        size = constant_offset(x[3])
        raise BorrowRefused, 'local byte-range analysis requires slot sizes from 1 to 4096' unless size > 0 && size <= 4096
        name = bname(x[1])
        raise BadIR, "duplicate local slot #{name}" if @slots[name]
        @slot_info[name] = [@slots.length, size, x[2]]
        @slots[name] = true
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
    @ancestors = {}
    @loans.each_key { |id| resolve_loan(id, []) }
    @loans.each_value do |loan|
      raise BadIR, "loan refers to unknown slot #{loan[0]}" unless @slots[loan[0]]
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

  def resolve_loan(id, visiting)
    raise BadIR, "unknown parent loan #{id}" unless @loans.key?(id)
    raise BadIR, "cyclic parent loan #{id}" if visiting.include?(id)
    return if @ancestors.key?(id)
    loan = @loans[id]
    parent = loan[2]
    if parent
      resolve_loan(parent, visiting + [id])
      loan[0] = @loans[parent][0]
      loan[3] += @loans[parent][3]
      @ancestors[id] = [parent] + @ancestors[parent]
    else
      @ancestors[id] = []
    end
    raise BadIR, "loan refers to unknown slot #{loan[0]}" unless @slots[loan[0]]
    loan[4] = type_width(loan[4], loan[0], loan[3])
    check_range(loan[0], loan[3], loan[4])
    if parent
      p = @loans[parent]
      raise BorrowRefused, 'reborrow range escapes its parent' unless loan[3] >= p[3] && loan[3] + loan[4] <= p[3] + p[4]
    end
  end

  def constant_offset(x)
    raise BadIR, 'constant byte offset required' unless x.is_a?(String)
    chars = x.start_with?('-') ? x[1..-1] : x
    raise BadIR, 'constant byte offset required' if chars.empty? || chars.bytes.any? { |c| c < 48 || c > 57 }
    x.to_i
  end

  def expression_offset(x)
    return 0 unless bh(x) == 'offset'
    raise BadIR, 'offset form' unless x.length == 3
    expression_offset(x[1]) + constant_offset(x[2])
  end

  def direct_place(x)
    return [x.name, 0] if x.is_a?(IRSym) && x.sig == '$'
    return nil unless bh(x) == 'offset' && x.length == 3
    base = direct_place(x[1])
    base ? [base[0], base[1] + constant_offset(x[2])] : nil
  end

  def type_width(ty, root = nil, off = 0)
    return 8 if bh(ty) == 'ptr'
    widths = {'bool'=>1, 'char'=>1, 'signed_char'=>1, 'unsigned_char'=>1,
              'short'=>2, 'unsigned_short'=>2, 'int'=>4, 'unsigned_int'=>4,
              'long'=>8, 'unsigned_long'=>8, 'long_long'=>8, 'unsigned_long_long'=>8,
              'float'=>4, 'double'=>8}
    return widths[ty] if widths.key?(ty)
    if root && off == 0 && @slot_info[root] && bh(ty) == bh(@slot_info[root][2]) &&
       bname(ty[1]) == bname(@slot_info[root][2][1])
      return @slot_info[root][1]
    end
    raise BorrowRefused, 'unknown aggregate access width'
  end

  def check_range(root, off, width)
    raise BadIR, "unknown local slot #{root}" unless @slot_info[root]
    raise BorrowRefused, 'local access is outside its storage range' unless off >= 0 && width >= 0 && off + width <= @slot_info[root][1]
  end

  def byte_key(root, off)
    'byte:' + @slot_info[root][0].to_s + ':' + off.to_s
  end

  def pointer_key(root, off, width)
    'pointer:' + @slot_info[root][0].to_s + ':' + off.to_s + ':' + width.to_s
  end

  def overlaps(a, n, b, m)
    n > 0 && m > 0 && a < b + m && b < a + n
  end

  def base_origin(origin)
    origin.start_with?('view:') ? @views[origin[5..-1].to_i][0] : origin
  end

  def address(origin)
    delta = 0
    if origin.start_with?('view:')
      origin, delta = @views[origin[5..-1].to_i]
    end
    return [origin[6..-1], delta, nil] if origin.start_with?('local:')
    if origin.start_with?('loan:')
      id = origin[5..-1]
      return [@loans[id][0], @loans[id][3] + delta, id]
    end
    nil
  end

  def project(origin, offset)
    base = base_origin(origin)
    return base if base.start_with?('expired:') || base.start_with?('ended:')
    old = origin.start_with?('view:') ? @views[origin[5..-1].to_i][1] : 0
    raise BorrowRefused, 'projection requires known local pointer provenance' unless address(origin)
    a = address(origin)
    check_range(a[0], a[1] + offset, 0)
    pair = [base, old + offset]
    unless @view_ids.key?(pair)
      @view_ids[pair] = 'view:' + @views.length.to_s
      @views << pair
    end
    @view_ids[pair]
  end

  def write_memory(root, off, width, state, provenance = nil)
    prefix = 'pointer:' + @slot_info[root][0].to_s + ':'
    state.keys.each do |key|
      next unless key.start_with?(prefix)
      parts = key.split(':')
      state[key] = ['unknown'] if overlaps(off, width, parts[2].to_i, parts[3].to_i)
    end
    width.times do |i|
      key = byte_key(root, off + i)
      state[key] = (state[key] || ['dead']).map { |s| s == 'dead' ? s : 'initialized' }.uniq.sort
    end
    state[pointer_key(root, off, width)] = provenance if provenance
  end

  def reset_storage(root, state, status, clear_pointers = true)
    @slot_info[root][1].times { |i| state[byte_key(root, i)] = [status] }
    prefix = 'pointer:' + @slot_info[root][0].to_s + ':'
    state.keys.each { |key| state[key] = ['unknown'] if key.start_with?(prefix) } if clear_pointers
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

  # Each storage state is a set: dead, uninitialized, initialized, moved. Pointer
  # provenance is a set of local storage identities, or external/unknown.
  def access(place, state, read, borrowing = nil, width = nil)
    base = base_origin(place)
    return if base == 'external'
    if base.start_with?('ended:')
      diagnostic('use-after-scope', base[6..-1])
      return
    end
    if base.start_with?('expired:')
      diagnostic('inactive-loan', base[8..-1])
      return
    end
    a = address(place)
    raise BorrowRefused, 'unknown pointer provenance' unless a
    name, off, own = a
    width ||= @slot_info[name][1]
    check_range(name, off, width)
    if own
      loan = @loans[own]
      raise BorrowRefused, 'access escapes its loan range' unless off >= loan[3] && off + width <= loan[3] + loan[4]
      ([own] + @ancestors[own]).each do |id|
        diagnostic('inactive-loan', id) unless state['loan:' + id] == ['active']
      end
      diagnostic('write-through-shared-loan', own) if !read && loan[1] == 'shared'
    end
    label = off == 0 && width == @slot_info[name][1] ? name : name + '[' + off.to_s + '..' + (off + width).to_s + ']'
    status = (0...width).flat_map { |i| state[byte_key(name, off + i)] || ['dead'] }.uniq
    diagnostic('use-after-scope', label) if status.include?('dead')
    diagnostic('uninitialized', label) if read && status.include?('uninitialized')
    diagnostic('use-after-move', label) if read && status.include?('moved')
    @loans.each do |id, loan|
      next if id == own || (own && @ancestors[own].include?(id)) || loan[0] != name || !(state['loan:' + id] || []).include?('active')
      next unless overlaps(off, width, loan[3], loan[4])
      diagnostic('loan-conflict', label + ' (' + id + ')') if loan[1] == 'exclusive' || !read || borrowing == 'exclusive'
    end
    [name, off, width]
  end

  def invalidate_pointers(state, from, to)
    state.keys.each do |entry|
      if entry.start_with?('value:') || entry.start_with?('pointer:')
        state[entry] = state[entry].map { |p| from.include?(base_origin(p)) ? to : p }.uniq
      end
    end
  end

  def storage(place)
    a = address(place)
    a ? a[0] : nil
  end

  def record_loan_values(values)
    if @record_uses
      values.each do |v|
        v = base_origin(v)
        id = nil
        id = v[5..-1] if v.start_with?('loan:')
        id = v[8..-1] if v.start_with?('expired:')
        @record_uses << id if id && !@record_uses.include?(id)
      end
    end
    values
  end

  def record_loan_definition(id)
    @record_defs << id if @record_defs && !@record_defs.include?(id)
  end

  def value(x, state)
    if x.is_a?(IRSym)
      return ['local:' + x.name] if x.sig == '$'
      return ['external']
    end
    if x.is_a?(String)
      return record_loan_values(state['value:' + x] || ['unknown']) if x.start_with?('%')
      return []
    end
    raise BadIR, 'operand form' unless x.is_a?(Array)
    case bh(x)
    when 'const'
      borrow_scalar_type!(x[1])
      bh(x[1]) == 'ptr' ? ['unknown'] : []
    when 'move-value', 'copy-value'
      raise BadIR, "#{bh(x)} form" unless x.length == 3
      borrow_scalar_type!(x[1])
      place = direct_place(x[2])
      raise BorrowRefused, 'value transfers require direct local slots or constant field offsets' unless place
      name, off = place
      raise BadIR, "value transfer refers to unknown slot #{name}" unless @slots[name]
      width = type_width(x[1])
      moving = bh(x) == 'move-value'
      access(project('local:' + name, off), state, true, moving ? 'exclusive' : nil, width)
      result = bh(x[1]) == 'ptr' ? record_loan_values(state[pointer_key(name, off, width)] || ['unknown']) : []
      if moving
        width.times do |i|
          key = byte_key(name, off + i)
          state[key] = (state[key] || ['dead']).map { |s| s == 'initialized' ? 'moved' : s }.uniq.sort
        end
      end
      result
    when 'borrow'
      id = bname(x[2])
      loan = @loans[id]
      record_loan_definition(id)
      diagnostic('loan-already-active', id) if state['loan:' + id].include?('active')
      access(project('local:' + loan[0], loan[3]), state, true, loan[1], loan[4])
      state['loan:' + id] = ['active']
      ['loan:' + id]
    when 'reborrow'
      id = bname(x[2])
      loan = @loans[id]
      parent = loan[2]
      record_loan_definition(id)
      sources = value(x[5], state)
      allowed = ['loan:' + parent, 'expired:' + parent]
      raise BorrowRefused, 'reborrow source must preserve declared parent identity' if sources.empty? || sources.any? { |p| !allowed.include?(base_origin(p)) }
      diagnostic('loan-already-active', id) if state['loan:' + id].include?('active')
      diagnostic('exclusive-reborrow-of-shared', id) if loan[1] == 'exclusive' && @loans[parent][1] == 'shared'
      sources.each do |p|
        a = address(p)
        raise BorrowRefused, 'reborrow source offset does not match its declared range' if a && a[1] != loan[3]
        access(p, state, true, loan[1], loan[4])
      end
      state['loan:' + id] = ['active']
      ['loan:' + id]
    when 'offset'
      raise BadIR, 'offset form' unless x.length == 3
      delta = constant_offset(x[2])
      value(x[1], state).map { |p| project(p, delta) }.uniq
    when 'load'
      borrow_scalar_type!(x[1])
      places = value(x[2], state)
      raise BorrowRefused, 'unknown pointer provenance' if places.empty?
      width = type_width(x[1])
      places.each { |p| access(p, state, true, nil, width) }
      if bh(x[1]) == 'ptr'
        record_loan_values(places.flat_map { |p| a = address(p); a ? (state[pointer_key(a[0], a[1], width)] || ['unknown']) : ['unknown'] }.uniq)
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
               'condition'=>[2], 'eval'=>[2], 'nonnull'=>[2], 'rref-arg'=>[2], 'loan-end'=>[2], 'zero-fill'=>[3]}
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
        reset_storage(name, state, 'uninitialized')
      end
    when 'scope-end'
      k = key(x[1])
      raise BadIR, 'scope-end requires a local slot' unless k && k.start_with?('slot:')
      name = k[5..-1]
      raise BadIR, "unknown local slot #{name}" unless @slots[name]
      reset_storage(name, state, 'dead', false)
      # A new lifetime in this slot cannot revive pointers from the old one.
      origins = ['local:' + name]
      @loans.each do |id, loan|
        next unless loan[0] == name
        record_loan_definition(id)
        diagnostic('scope-end-with-loan', id) if state['loan:' + id].include?('active')
        origins << 'loan:' + id
        state['loan:' + id] = ['ended']
      end
      invalidate_pointers(state, origins, 'ended:' + name)
    when 'loan-end'
      raise BadIR, 'loan-end form' unless x[1].is_a?(IRStr)
      id = bname(x[1])
      raise BadIR, "unknown loan #{id}" unless @loans.key?(id)
      record_loan_definition(id)
      status = state['loan:' + id]
      valid = status == ['active'] || (@infer_loan_ends && status.all? { |s| ['active', 'inferred-ended'].include?(s) })
      diagnostic('inactive-loan', id) unless valid
      @loans.each_key do |child|
        next unless @ancestors[child].include?(id)
        record_loan_definition(child)
        diagnostic('loan-end-with-child', id) if state['loan:' + child].include?('active')
        state['loan:' + child] = ['ended']
        invalidate_pointers(state, ['loan:' + child], 'expired:' + child)
      end
      state['loan:' + id] = ['ended']
      invalidate_pointers(state, ['loan:' + id], 'expired:' + id)
    when 'let', 'set'
      borrow_scalar_type!(x[2])
      v = value(x[3], state)
      raise BadIR, 'register destination' unless x[1].is_a?(String) && x[1].start_with?('%')
      state['value:' + x[1]] = v
    when 'store', 'zero-fill'
      zero = bh(x) == 'zero-fill'
      borrow_scalar_type!(x[1]) unless zero
      width = zero ? constant_offset(x[1]) : type_width(x[1])
      raise BadIR, 'negative zero-fill length' if width < 0
      v = zero ? nil : value(x[3], state)
      dest = value(x[2], state)
      dest.each { |p| access(p, state, false, nil, width) }
      raise BorrowRefused, 'store through external storage may escape a local address' if dest.any? { |p| base_origin(p) == 'external' }
      raise BorrowRefused, 'store through an aliased destination' unless dest.length == 1
      a = address(dest[0])
      return state unless a
      write_memory(a[0], a[1], width, state, !zero && bh(x[1]) == 'ptr' ? v : nil)
    when 'return'
      refs = x[1] ? value(x[1], state) : []
      raise BorrowRefused, 'return with unknown pointer provenance' if refs.include?('unknown')
      refs.each do |p|
        next if p == 'external'
        if p.start_with?('expired:')
          diagnostic('inactive-loan', p[8..-1])
        else
          diagnostic('return-local-address', base_origin(p).start_with?('ended:') ? base_origin(p)[6..-1] : storage(p))
        end
      end
    when 'condition', 'eval', 'nonnull'
      value(x[1], state)
    when 'rref-arg'
      raise BorrowRefused, 'rvalue-reference arguments require language-specific move contracts'
    else
      raise BorrowRefused, "statement #{bh(x)}"
    end
    state
  end

  def initial_state
    initial = {}
    @slots.each_key { |s| reset_storage(s, initial, 'dead') }
    @params.each do |p, name, pointer|
      initial['value:' + p] = pointer ? ['external'] : []
      reset_storage(name, initial, 'uninitialized') if @slots[name]
    end
    @loans.each_key { |id| initial['loan:' + id] = ['inactive'] }
    initial
  end

  def expire_dead_loans(state, needed)
    @loans.each_key do |id|
      status = state['loan:' + id]
      next if needed.include?(id) || !status.include?('active')
      state['loan:' + id] = status.map { |s| s == 'active' ? 'inferred-ended' : s }.uniq.sort
      invalidate_pointers(state, ['loan:' + id], 'expired:' + id)
    end
    state
  end

  def solve(expire = false)
    incoming = { @entry => initial_state }
    queue = [@entry]
    until queue.empty?
      id = queue.shift
      out = transfer(@nodes[id][0], incoming[id].dup)
      @nodes[id][1].each do |succ|
        edge = expire ? expire_dead_loans(out.dup, @needed[succ]) : out
        old = incoming[succ]
        merged = edge.dup
        if old
          (old.keys + edge.keys).uniq.each do |k|
            # Missing register definitions cannot acquire provenance from just
            # one predecessor. Slot entries exist on every path.
            a = old[k] || ['unknown']
            b = edge[k] || ['unknown']
            merged[k] = (a + b).uniq.sort
          end
        end
        if old != merged
          incoming[succ] = merged
          queue << succ unless queue.include?(succ)
        end
      end
    end
    incoming
  end

  # Recover uses from converged provenance first, without shrinking lifetimes.
  # This prevents tentative expiry from hiding a later use. Creation and
  # explicit end kill demands for the previous instance of a static loan ID.
  def infer_needed_loans(incoming)
    uses = {}
    defs = {}
    incoming.each do |id, state|
      @record_uses = []
      @record_defs = []
      transfer(@nodes[id][0], state.dup)
      uses[id] = @record_uses
      defs[id] = @record_defs
    end
    @record_uses = nil
    @record_defs = nil
    @needed = Array.new(@nodes.length) { [] }
    changed = true
    while changed
      changed = false
      incoming.keys.reverse_each do |id|
        after = @nodes[id][1].flat_map { |succ| @needed[succ] }.uniq
        before = (uses[id] + (after - defs[id])).uniq
        # A child can remain usable only while its ancestor chain remains live.
        before = before.flat_map { |loan| [loan] + @ancestors[loan] }.uniq.sort
        if @needed[id] != before
          @needed[id] = before
          changed = true
        end
      end
    end
  end

  def run
    return if @entry.nil?
    incoming = solve
    if @infer_loan_ends
      infer_needed_loans(incoming)
      incoming = solve(true)
    end
    @report = true
    incoming.each { |id, s| transfer(@nodes[id][0], s.dup) }
  end
end

begin
  args = ARGV.dup
  infer = args[0] == '--infer-loan-ends'
  args.shift if infer
  raise BadIR, 'usage: scripts/mrb scripts/pathb-borrowck.rb [--infer-loan-ends] FILE.ir' unless args.length == 1
  forms = parse_forms(tokenize(File.read(args[0])))
  raise BadIR, 'missing ir-module' unless bh(forms[0]) == 'ir-module'
  layout = forms[0].find { |part| bh(part) == 'layout' }
  expected_widths = {'pointer'=>'8', 'short'=>'2', 'int'=>'4', 'long'=>'8', 'long_long'=>'8', 'float'=>'4', 'double'=>'8'}
  if layout
    layout.drop(1).each do |part|
      if part.is_a?(Array) && expected_widths.key?(part[0]) && part[1] != expected_widths[part[0]]
        raise BorrowRefused, 'byte-range analysis currently requires LP64 layout'
      end
    end
  end
  functions = forms.select { |f| bh(f) == 'function' }
  raise BorrowRefused, 'no functions to analyze' if functions.empty?
  errors = []
  functions.each do |f|
    checker = LocalLifetime.new(f, infer)
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
