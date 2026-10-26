# Local lifetime analysis for annotated Path B IR. Run with scripts/mrb.
# --infer-loan-ends enables conservative last-use inference; default uses explicit ends.
# --effects FILE adds trusted call-effects forms for functions the module does not describe.
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


# A type without its outer const qualifiers.
def unconst(ty)
  ty = ty[1] while bh(ty) == 'const' && ty.length == 2
  ty
end

def bh(x)
  x.is_a?(Array) ? x[0] : nil
end

def borrow_scalar_type!(ty)
  ty = unconst(ty)
  return if bh(ty) == 'ptr'
  scalars = %w[bool char signed_char unsigned_char short unsigned_short int unsigned_int long unsigned_long long_long unsigned_long_long float double]
  raise BorrowRefused, 'aggregate/unsupported values need field-sensitive provenance' unless scalars.include?(ty)
end

def bname(x)
  x.is_a?(IRStr) ? x.to_s : x
end

# Semantic layouts are checker contracts, not ABI classification. Keep this
# validator in sync in the standalone checker, QBE emitter, and emitter oracle.
class BorrowLayouts
  PRIMITIVES = {'bool'=>1, 'char'=>1, 'signed_char'=>1, 'unsigned_char'=>1,
                'short'=>2, 'unsigned_short'=>2, 'int'=>4, 'unsigned_int'=>4,
                'long'=>8, 'unsigned_long'=>8, 'long_long'=>8, 'unsigned_long_long'=>8,
                'float'=>4, 'double'=>8}

  def initialize(forms, bad, refused)
    @bad = bad
    @refused = refused
    @raw = {}
    @resolved = {}
    forms.each do |f|
      next unless head(f) == 'borrow-layout'
      raise @bad, 'borrow-layout form' unless f.length >= 4
      raise @refused, 'semantic layouts currently require struct types' unless head(f[1]) == 'struct'
      k = key(f[1])
      raise @bad, "duplicate semantic layout #{k[1]}" if @raw.key?(k)
      @raw[k] = f
    end
    @raw.each_key { |k| resolve(k, []) }
  end

  def head(x)
    x.is_a?(Array) ? x[0] : nil
  end

  def key(ty)
    return nil unless head(ty) == 'struct'
    raise @bad, 'semantic layout type form' unless ty.length == 2 && ty[1].is_a?(IRStr) && !ty[1].to_s.empty?
    ['struct', ty[1].to_s]
  end

  def number(x)
    unless x.is_a?(String) && !x.empty? && x.bytes.all? { |c| c >= 48 && c <= 57 }
      raise @bad, 'semantic layout requires nonnegative integer constants'
    end
    x.to_i
  end

  def lookup(ty)
    k = key(ty)
    k ? @resolved[k] : nil
  end

  def field_type(ty, visiting)
    if ty.is_a?(String) && PRIMITIVES.key?(ty)
      n = PRIMITIVES[ty]
      return {size: n, align: n, used: (0...n).to_a, objects: []}
    end
    if head(ty) == 'ptr'
      raise @bad, 'semantic pointer field type' unless ty.length == 2
      return {size: 8, align: 8, used: (0...8).to_a, objects: []}
    end
    if head(ty) == 'array'
      raise @bad, 'semantic array field type' unless ty.length == 3
      count = number(ty[1])
      elem = field_type(ty[2], visiting)
      n = elem[:size]
      raise @refused, 'semantic arrays need 1 to 4096 bytes' unless count > 0 && count * n <= 4096
      return {size: count * n, align: elem[:align],
              used: (0...count).flat_map { |i| elem[:used].map { |b| i * n + b } },
              objects: (0...count).flat_map { |i| elem[:objects].map { |o, t| [i * n + o, t] } }}
    end
    k = key(ty)
    raise @refused, 'unsupported semantic field type' unless k
    resolve(k, visiting)
  end

  def resolve(k, visiting)
    raise @bad, "cyclic semantic layout #{k[1]}" if visiting.include?(k)
    return @resolved[k] if @resolved.key?(k)
    raise @bad, "unknown semantic layout #{k[1]}" unless @raw.key?(k)
    f = @raw[k]
    size = number(f[2])
    align = number(f[3])
    unless size > 0 && size <= 4096 && align > 0 && align <= 4096 && (align & (align - 1)) == 0 && size % align == 0
      raise @bad, "invalid semantic size/alignment for #{k[1]}"
    end
    names = {}
    ranges = []
    used = []
    objects = [[0, k]]
    f.drop(4).each do |field|
      unless head(field) == 'field' && field.length == 4 && field[1].is_a?(IRStr) && !field[1].to_s.empty?
        raise @bad, 'semantic field form'
      end
      name = field[1].to_s
      raise @bad, "duplicate semantic field #{name}" if names[name]
      names[name] = true
      off = number(field[2])
      desc = field_type(field[3], visiting + [k])
      n = desc[:size]
      raise @bad, "semantic field #{name} exceeds its object" if off + n > size
      raise @refused, 'unaligned semantic fields are unsupported' if off % desc[:align] != 0 || align < desc[:align]
      if ranges.any? { |o, len| off < o + len && o < off + n }
        raise @refused, 'overlapping semantic fields are unsupported'
      end
      ranges << [off, n]
      used.concat(desc[:used].map { |i| off + i })
      objects.concat(desc[:objects].map { |o, ty| [off + o, ty] })
    end
    @resolved[k] = {size: size, align: align, used: used.sort, objects: objects}
  end
end

# Closed summaries are trusted at calls. A body defined in the same module is
# checked against its summary (LocalLifetime#contract_regions).
# Keep this validator synchronized across the three standalone IR tools.
class BorrowCallEffects
  attr_accessor :entries

  def initialize(forms, layouts, bad, refused)
    @entries = {}
    @layouts = layouts
    @bad = bad
    @refused = refused
    forms.each do |f|
      next unless f.is_a?(Array) && f[0] == 'call-effects'
      name, entry = parse(f)
      raise bad, "duplicate call effects #{name}" if @entries.key?(name)
      @entries[name] = entry
    end
  end

  # A copy whose entry for NAME is replaced by FORM, or removed when FORM is nil.
  def with(name, form)
    copy = dup
    entries = @entries.dup
    copy.entries = entries
    if form
      entries[name] = parse(form)[1]
    else
      entries.delete(name)
    end
    copy
  end

  def parse(f)
    layouts = @layouts
    bad = @bad
    refused = @refused
    unless f.length == 7 && f[1].is_a?(IRStr) && !f[1].to_s.empty? &&
           f[2].is_a?(Array) && f[2][0] == 'returns' && [2, 3].include?(f[2].length) &&
           f[6].is_a?(Array) && f[6][0] == 'args'
      raise bad, 'call-effects form'
    end
    name = f[1].to_s
    unless %w[nothrow may-throw].include?(bh(f[3])) && f[3].length == 1 && f[4] == ['noescape'] && f[5] == ['closed']
      raise refused, 'call contracts require nothrow or may-throw, noescape, and closed effects'
    end
    result = f[2][1]
    alias_result = f[2][2]
    unless alias_result || result == 'void' || (result.is_a?(String) && BorrowLayouts::PRIMITIVES.key?(result))
      raise refused, 'call effects support only void or scalar results'
    end
    args = f[6].drop(1)
    args.each do |arg|
      unless arg.is_a?(Array) && arg.length == 2 && %w[value read write init consume byval].include?(arg[0])
        raise bad, 'call argument effect form'
      end
      ty = arg[1]
      if arg[0] == 'value'
        unless ty.is_a?(String) && BorrowLayouts::PRIMITIVES.key?(ty)
          raise refused, 'value effects require nonpointer scalar arguments'
        end
      elsif ty.is_a?(Array) && ty[0] == 'struct' && !layouts.lookup(ty)
        raise refused, 'call aggregate effects require semantic layouts'
      else
        layouts.field_type(ty, [])
      end
    end
    if alias_result
      unless result.is_a?(Array) && result[0] == 'ptr' && result.length == 2 &&
             alias_result.is_a?(Array) && alias_result.length == 4 && alias_result[0] == 'from-arg' &&
             %w[shared exclusive].include?(alias_result[3])
        raise bad, 'returned alias contract form'
      end
      index = layouts.number(alias_result[1])
      offset = layouts.number(alias_result[2])
      source = args[index]
      unless source && %w[read write].include?(source[0])
        raise refused, 'returned aliases require a read or write source argument'
      end
      if alias_result[3] == 'exclusive' && source[0] != 'write'
        raise refused, 'exclusive returned aliases require a write source argument'
      end
      # A pointer to const grants no writes, so its alias is shared.
      pointee = result[1]
      pointee = pointee[1] while pointee.is_a?(Array) && pointee[0] == 'const' && pointee.length == 2
      if !pointee.equal?(result[1]) && alias_result[3] != 'shared'
        raise refused, 'returned aliases of const pointees must be shared'
      end
      width = layouts.field_type(pointee, [])[:size]
      if offset + width > layouts.field_type(source[1], [])[:size]
        raise refused, 'returned alias range escapes its source argument'
      end
      alias_result = {arg: index, offset: offset, kind: alias_result[3]}
    elsif result.is_a?(Array)
      raise refused, 'call effects support only void or scalar results'
    end
    [name, {result: result, args: args, alias: alias_result, throws: bh(f[3]) == 'may-throw'}]
  end

  def lookup(name)
    @entries[name]
  end
end

class LocalLifetime
  attr_reader :errors

  # true when the body calls a callee that may throw (other than the function itself)
  attr_reader :throws

  def initialize(f, infer_loan_ends = false, semantic_layouts = nil, call_effects = nil, abi_sizes = {})
    @infer_loan_ends = infer_loan_ends
    @layouts = semantic_layouts || BorrowLayouts.new([], BadIR, BorrowRefused)
    @call_effects = call_effects || BorrowCallEffects.new([], @layouts, BadIR, BorrowRefused)
    raise BadIR, 'function header' unless f.length >= 4 && bh(f[2]) == 'ret' && bh(f[3]) == 'params'
    @name = bname(f[1])
    @ret = f[2][1]
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
    @drops = {}
    @register_types = {}
    @symbols = {}
    @implicit_loans = {}
    @byval = {}
    @register_defs = {}
    defs = lambda do |x|
      next unless x.is_a?(Array)
      if %w[param let set].include?(bh(x)) && x.length >= 3 && x[1].is_a?(String)
        (@register_defs[x[1]] ||= []) << x
      end
      x.each { |y| defs.call(y) }
    end
    f.each { |x| defs.call(x) }
    scan = lambda do |x|
      @symbols[x.name] = true if x.is_a?(IRSym) && x.sig == '$'
      return unless x.is_a?(Array)
      if %w[param let set].include?(bh(x)) && x.length == 4 && x[1].is_a?(String)
        ty = bh(x) == 'param' ? x[3] : x[2]
        list = (@register_types[x[1]] ||= [])
        list << ty unless list.any? { |old| same_type?(old, ty) }
      end
      if bh(x) == 'decl'
        @has_facts = true
        @declared[x[1].name] = true if x[1].is_a?(IRSym) && x[1].sig == '$'
      end
      if bh(x) == 'borrow'
        raise BadIR, 'borrow form' unless x.length == 5 && bh(x[1]) == 'ptr' && x[2].is_a?(IRStr) && %w[shared exclusive].include?(x[3])
        id = bname(x[2])
        raise BadIR, "duplicate loan #{id}" if @loans.key?(id)
        place = direct_place(x[4])
        raise BorrowRefused, 'borrow requires a direct local place or constant field offset; use reborrow with an explicit parent' unless place
        @loans[id] = [place[0], x[3], nil, place[1], unconst(x[1][1]), unconst(x[1][1])]
      end
      if bh(x) == 'call-borrow'
        unless x.length >= 5 && bh(x[1]) == 'ptr' && x[2].is_a?(IRStr) &&
               x[4].is_a?(IRSym) && x[4].sig == '&'
          raise BadIR, 'call-borrow form'
        end
        summary = @call_effects.lookup(x[4].name)
        raise BorrowRefused, 'call-borrow requires a returned alias contract' unless summary && summary[:alias]
        raise BadIR, 'call return type disagrees with its effect contract' unless same_type?(x[1], summary[:result])
        a = summary[:alias]
        source = x[5 + a[:arg]]
        raise BadIR, 'call arity disagrees with its effect contract' unless x.length - 5 == summary[:args].length
        id = bname(x[2])
        raise BadIR, "duplicate loan #{id}" if @loans.key?(id)
        if x[3] == 'root'
          place = direct_place(source)
          raise BorrowRefused, 'root returned aliases require a direct local place' unless place
          @loans[id] = [place[0], a[:kind], nil, place[1] + a[:offset], unconst(x[1][1]), unconst(x[1][1])]
        elsif bh(x[3]) == 'parent' && x[3].length == 2 && x[3][1].is_a?(IRStr)
          @loans[id] = [nil, a[:kind], bname(x[3][1]), expression_offset(source) + a[:offset], unconst(x[1][1]), unconst(x[1][1])]
        else
          raise BadIR, 'call-borrow parent form'
        end
      end
      # A plain call to a returned-alias contract whose source is a direct place
      # gets an implicit root loan for this call site, so lowered C++ needs no
      # call-borrow form. Its end must come from last-use inference.
      if bh(x) == 'call' && x.length >= 3 && x[2].is_a?(IRSym) && x[2].sig == '&'
        summary = @call_effects.lookup(x[2].name)
        a = summary && summary[:alias]
        place = a && x.length - 3 == summary[:args].length ? cast_place(x[3 + a[:arg]]) : nil
        if place && bh(x[1]) == 'ptr'
          id = '&' + x[2].name + '#' + (@implicit_loans.length + 1).to_s
          raise BadIR, "duplicate loan #{id}" if @loans.key?(id)
          @loans[id] = [place[0], a[:kind], nil, place[1] + a[:offset], unconst(x[1][1]), unconst(x[1][1])]
          @implicit_loans[x.object_id] = id
        end
      end
      if bh(x) == 'reborrow'
        raise BadIR, 'reborrow form' unless x.length == 6 && bh(x[1]) == 'ptr' && x[2].is_a?(IRStr) && x[4].is_a?(IRStr) && %w[shared exclusive].include?(x[3])
        id = bname(x[2])
        raise BadIR, "duplicate loan #{id}" if @loans.key?(id)
        @loans[id] = [nil, x[3], bname(x[4]), expression_offset(x[5]), unconst(x[1][1]), unconst(x[1][1])]
      end
      x.each { |y| scan.call(y) }
    end
    scan.call(f)
    # (loc "FILE" LINE) statements (NFCXX_IR_LOC=1) give the place of the statements after them, in text order.
    # Diagnostics name that place; without loc forms the messages are unchanged.
    @locs = {}
    cur = nil
    where = lambda do |x|
      next unless x.is_a?(Array)
      if bh(x) == 'loc' && x.length == 3 && x[1].is_a?(IRStr)
        cur = [x[1].to_s, x[2].to_s]
      end
      @locs[x.object_id] = cur if cur
      x.each { |y| where.call(y) }
    end
    where.call(f)
    # IR printed without the flag has no facts. A function with no slot and no
    # parameter has nothing to declare either way.
    needs_facts = f.drop(4).any? { |part| bh(part) == 'slot' } || f[3].length > 1
    raise BorrowRefused, 'no local declaration facts; use NFCXX_PATHB_BORROW=1' if needs_facts && !@has_facts
    if !@implicit_loans.empty? && !@infer_loan_ends
      raise BorrowRefused, 'returned aliases from plain calls need call-borrow or --infer-loan-ends'
    end
    f.drop(4).each do |x|
      if bh(x) == 'slot'
        raise BadIR, 'slot form' unless x.length == 5
        borrow_scalar_type!(x[2]) unless %w[struct union array].include?(bh(x[2]))
        size = constant_offset(x[3])
        raise BorrowRefused, 'local byte-range analysis requires slot sizes from 1 to 4096' unless size > 0 && size <= 4096
        name = bname(x[1])
        raise BadIR, "duplicate local slot #{name}" if @slots[name]
        align = constant_offset(x[4])
        desc = @layouts.lookup(x[2])
        if desc && (size != desc[:size] || align < desc[:align] || align % desc[:align] != 0)
          raise BadIR, "slot #{name} disagrees with semantic layout"
        end
        @slot_info[name] = [@slots.length, size, x[2], align]
        @slots[name] = true
      end
    end
    f[3].drop(1).each do |p|
      if bh(p) == 'sret'
        # The caller's buffer for an aggregate result: a pointer the callee must initialize (summary mode init).
        raise BadIR, 'sret form' unless p.length == 3 && p[1].is_a?(String)
        @params << [p[1], nil, true, ['ptr', p[2]]]
        next
      end
      raise BorrowRefused, 'variadic functions are unsupported' if bh(p) == 'ellipsis'
      raise BadIR, 'param form' unless bh(p) == 'param' && p.length == 4
      @params << [p[1], bname(p[2]), bh(unconst(p[3])) == 'ptr', unconst(p[3])]
      if bh(p[3]) == 'byval'
        # The register is the address of the callee's own initialized copy: a
        # synthetic local that lives for the whole call.
        ty = p[3][1]
        desc = @layouts.lookup(ty)
        size = desc ? desc[:size] : (bh(ty) == 'struct' && ty[1].is_a?(IRStr) ? abi_sizes[ty[1].to_s] : nil)
        raise BorrowRefused, 'by-value parameter of unknown size' unless size && size > 0
        name = '*' + p[1]
        raise BadIR, "by-value parameter slot #{name} collides with another name" if @slots[name] || @symbols[name]
        @slot_info[name] = [@slots.length, size, ty, desc ? desc[:align] : 1]
        @slots[name] = true
        @declared[name] = true
        @byval[p[1]] = name
      end
    end
    @slots.each_key do |name|
      unless @declared[name] || @params.any? { |p| p[1] == name }
        raise BorrowRefused, "missing declaration facts for slot #{name}"
      end
    end
    @summary = @call_effects.lookup(@name)
    @regions = {}
    contract_regions if @summary
    @ancestors = {}
    @loans.each_key { |id| resolve_loan(id, []) }
    @loans.each_value do |loan|
      raise BadIR, "loan refers to unknown slot #{loan[0]}" unless @slots[loan[0]]
    end
    f.drop(4).each do |part|
      next unless bh(part) == 'drop-obligation'
      unless part.length == 4 && part[1].is_a?(IRStr) && !part[1].to_s.empty?
        raise BadIR, 'drop-obligation form'
      end
      id = part[1].to_s
      raise BadIR, "duplicate drop obligation #{id}" if @drops.key?(id)
      place = direct_place(part[3])
      raise BorrowRefused, 'drop obligations require direct local slots or constant field offsets' unless place
      root, off = place
      raise BadIR, "drop obligation refers to unknown slot #{root}" unless @slots[root]
      ty = part[2]
      desc = @layouts.lookup(ty)
      if %w[struct union array].include?(bh(ty)) && !desc
        raise BorrowRefused, 'aggregate drop obligations require semantic layouts'
      end
      width = type_width(ty, root, off)
      check_range(root, off, width)
      required = semantic_bytes(root, off, ty) || (0...width).to_a
      if @drops.values.any? { |d| d[:root] == root && overlaps(off, width, d[:off], d[:width]) }
        raise BorrowRefused, 'overlapping drop obligations require hierarchical cleanup contracts'
      end
      @drops[id] = {root: root, off: off, width: width, type: ty, required: required}
    end
    @regions.each_value do |r|
      next unless r[:mode] == 'consume'
      raise BadIR, "drop obligation #{r[:name]} collides with a contract argument" if @drops.key?(r[:name])
      @drops[r[:name]] = {root: r[:name], off: 0, width: r[:width], type: r[:type], required: r[:required]}
    end
    body = f.drop(4).reject { |x| ['slot', 'static', 'weak', 'drop-obligation'].include?(bh(x)) }
    @try_stack = []
    @exc = {}
    @entry = sequence(body, node(['function-exit'], []), nil, nil)
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

  # A defined function with a call-effects summary is checked against it. Each
  # memory argument's pointee becomes a region named *%N. Read, write, and init
  # arguments are reached through a loan of that name lasting the whole call;
  # consume arguments are owned places with a live obligation of that name.
  def contract_regions
    unless same_type?(@ret, @summary[:result])
      raise BadIR, 'function return type disagrees with its effect contract'
    end
    unless @params.length == @summary[:args].length
      raise BadIR, 'function arity disagrees with its effect contract'
    end
    @params.each_with_index do |(reg, _name, pointer, pty), i|
      mode, ty = @summary[:args][i]
      if mode == 'byval'
        # The parameter is the callee's own copy (the synthetic slot *%N).
        unless bh(pty) == 'byval' && same_type?(pty[1], ty)
          raise BadIR, 'function parameter disagrees with its effect contract'
        end
        next
      end
      if mode == 'value'
        unless !pointer && scalar_abi_class(pty) == scalar_abi_class(ty)
          raise BadIR, 'function parameter disagrees with its effect contract'
        end
        next
      end
      raise BadIR, 'function parameter disagrees with its effect contract' unless pointer
      name = '*' + reg
      if @slots[name] || @symbols[name] || @loans.key?(name)
        raise BadIR, "contract argument #{name} collides with a local name"
      end
      desc = @layouts.lookup(ty)
      width = type_width(ty)
      @slot_info[name] = [@slots.length, width, ty, desc ? desc[:align] : width]
      @slots[name] = true
      required = semantic_bytes(name, 0, ty) || (0...width).to_a
      @regions[reg] = {name: name, mode: mode, type: ty, width: width, required: required}
      @loans[name] = [name, mode == 'read' ? 'shared' : 'exclusive', nil, 0, ty, ty] unless mode == 'consume'
    end
  end

  # Write and init promise defined fields on every normal return; consume
  # obligations are checked with the other pending drops.
  def check_contract_exit(state)
    @regions.each_value do |r|
      next unless %w[write init].include?(r[:mode])
      ok = r[:required].all? { |i| state[byte_key(r[:name], i)] == ['initialized'] }
      diagnostic('contract-output-uninitialized', r[:name]) unless ok
    end
  end

  def check_contract_return(refs)
    a = @summary[:alias]
    return unless a
    region = @regions[@params[a[:arg]][0]][:name]
    diagnostic('contract-return-mismatch', region) if refs.empty?
    refs.each do |p|
      next if base_origin(p).start_with?('expired:') || base_origin(p).start_with?('ended:')
      root, off, own = address(p)
      exact = root == region && off == a[:offset] && own &&
              (a[:kind] == 'shared' || ([own] + @ancestors[own]).all? { |id| @loans[id][1] == 'exclusive' })
      diagnostic('contract-return-mismatch', region) unless exact
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
    semantic_bytes(loan[0], loan[3], loan[5])
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

  # A direct place, or a register defined once as a pointer cast of one (the
  # qualification conversion C++ inserts for a pointer-to-const argument).
  def cast_place(x)
    place = direct_place(x)
    return place if place || !(x.is_a?(String) && x.start_with?('%'))
    d = @register_defs[x]
    return nil unless d && d.length == 1 && bh(d[0]) == 'let' && d[0].length == 4
    e = d[0][3]
    return nil unless bh(e) == 'bitcast' && e.length == 3 && bh(e[1]) == 'ptr'
    direct_place(e[2])
  end

  def direct_place(x)
    return [x.name, 0] if x.is_a?(IRSym) && x.sig == '$'
    return nil unless bh(x) == 'offset' && x.length == 3
    base = direct_place(x[1])
    base ? [base[0], base[1] + constant_offset(x[2])] : nil
  end

  def type_width(ty, root = nil, off = 0)
    desc = @layouts.lookup(ty)
    return desc[:size] if desc
    return 8 if bh(ty) == 'ptr'
    return @layouts.field_type(ty, [])[:size] if bh(ty) == 'array'
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

  def semantic_bytes(root, off, ty)
    desc = @layouts.lookup(ty)
    return nil unless desc
    root_type = @slot_info[root][2]
    root_desc = @layouts.lookup(root_type)
    # A byte array of the struct's exact size holds the same value (the frontend types a long double or __int128
    # value as a byte array, and passes it to a struct parameter). Its whole object is the struct's, so the struct's
    # significant bytes are the ones required.
    if root_desc.nil? && off == 0 && bh(root_type) == 'array' && root_type.length == 3 && root_type[2] == 'unsigned_char' &&
       root_type[1].is_a?(String) && root_type[1].to_i == desc[:size] && desc[:size] == @slot_info[root][1]
      return desc[:used]
    end
    unless root_desc && root_desc[:objects].include?([off, @layouts.key(ty)])
      raise BorrowRefused, 'semantic aggregate borrow does not match a declared subobject'
    end
    desc[:used]
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

  # A ranged view points somewhere within the array its base names: the whole
  # array slot, or the range of a loan of one. Dynamic indices produce it, and
  # so does a join of different offsets from one base.
  def ranged?(origin)
    origin.start_with?('view:') && @views[origin[5..-1].to_i][1].nil?
  end

  def array_range(base)
    if base.start_with?('local:')
      root = base[6..-1]
      lo, n, own = 0, @slot_info[root] && @slot_info[root][1], nil
    elsif base.start_with?('loan:')
      own = base[5..-1]
      root, lo, n = @loans[own][0], @loans[own][3], @loans[own][4]
    else
      return nil
    end
    return nil unless @slot_info[root] && bh(@slot_info[root][2]) == 'array'
    return nil if @regions.values.any? { |r| r[:name] == root }
    [root, lo, n, own]
  end

  def ranged(origin)
    base = base_origin(origin)
    return base if base.start_with?('expired:') || base.start_with?('ended:')
    raise BorrowRefused, 'pointer arithmetic requires a local array object' unless array_range(base)
    pair = [base, nil]
    unless @view_ids.key?(pair)
      @view_ids[pair] = 'view:' + @views.length.to_s
      @views << pair
    end
    @view_ids[pair]
  end

  # Merge the origins of one base at different offsets into its ranged view,
  # so that a pointer advanced in a loop converges.
  def widen(values)
    groups = {}
    values.each do |p|
      base = base_origin(p)
      next unless base.start_with?('local:') || base.start_with?('loan:')
      (groups[base] ||= []) << p
    end
    groups.each do |base, ps|
      next if ps.length < 2 || !array_range(base)
      values = (values - ps + [ranged(base)]).uniq.sort
    end
    values
  end

  def project(origin, offset)
    base = base_origin(origin)
    return base if base.start_with?('expired:') || base.start_with?('ended:')
    return origin if ranged?(origin)
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

  def forget_pointer_values(root, off, width, state)
    prefix = 'pointer:' + @slot_info[root][0].to_s + ':'
    state.keys.each do |key|
      next unless key.start_with?(prefix)
      parts = key.split(':')
      state[key] = ['unknown'] if overlaps(off, width, parts[2].to_i, parts[3].to_i)
    end
  end

  def write_memory(root, off, width, state, provenance = nil)
    forget_pointer_values(root, off, width, state)
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

  def same_type?(a, b)
    return a.is_a?(IRStr) && b.is_a?(IRStr) && a.to_s == b.to_s if a.is_a?(IRStr) || b.is_a?(IRStr)
    if a.is_a?(Array) || b.is_a?(Array)
      return false unless a.is_a?(Array) && b.is_a?(Array) && a.length == b.length
      return a.each_with_index.all? { |v, i| same_type?(v, b[i]) }
    end
    a == b
  end

  def drop_key(id)
    'drop:' + id
  end

  def reset_drop_flags(root, state, status)
    @drops.each { |id, d| state[drop_key(id)] = [status] if d[:root] == root }
  end

  def check_pending_drops(state, root = nil)
    @drops.each do |id, d|
      next if root && d[:root] != root
      flags = state[drop_key(id)]
      diagnostic('missing-drop', id) if flags.include?('live')
      diagnostic('unarmed-drop-value', id) if flags.include?('building')
    end
  end

  def track_drop_write(root, off, width, state)
    @drops.each do |id, d|
      next unless d[:root] == root && overlaps(off, width, d[:off], d[:width])
      flags = state[drop_key(id)]
      full = off <= d[:off] && off + width >= d[:off] + d[:width]
      diagnostic('overwrite-live-drop', id) if full && flags.include?('live')
      state[drop_key(id)] = flags.map { |f| ['dead', 'live'].include?(f) ? f : 'building' }.uniq.sort
    end
  end

  def track_drop_transfer(root, off, width, ty, moving, state)
    @drops.each do |id, d|
      next unless d[:root] == root && overlaps(off, width, d[:off], d[:width])
      exact = off == d[:off] && width == d[:width] && same_type?(ty, d[:type])
      if moving && !exact
        raise BorrowRefused, 'partial or reinterpreted moves of drop-obligated values require cleanup contracts'
      end
      flags = state[drop_key(id)]
      if !moving && exact && flags.include?('live')
        raise BorrowRefused, 'copy of a drop-obligated value requires a copy contract'
      end
      next unless moving
      diagnostic('move-unarmed-drop', id) if flags.include?('building')
      state[drop_key(id)] = flags.map { |f| f == 'live' ? 'vacant' : f }.uniq.sort
    end
  end

  def drop_event(x, state)
    unless x.length == 2 && x[1].is_a?(IRStr) && @drops.key?(x[1].to_s)
      raise BadIR, 'drop event requires a declared obligation ID'
    end
    id = x[1].to_s
    d = @drops[id]
    flags = state[drop_key(id)]
    root, off, width = d[:root], d[:off], d[:width]
    place = project('local:' + root, off)
    if bh(x) == 'drop-live'
      diagnostic('drop-already-live', id) if flags.include?('live')
      access(place, state, true, nil, width, d[:type])
      live_storage = (0...width).all? { |i| !(state[byte_key(root, off + i)] || ['dead']).include?('dead') }
      complete = d[:required].all? { |i| state[byte_key(root, off + i)] == ['initialized'] }
      state[drop_key(id)] = ['live'] if live_storage && complete
      return state
    end
    diagnostic('drop-outside-storage', id) if flags.include?('dead')
    diagnostic('unarmed-drop-value', id) if flags.include?('building')
    if bh(x) == 'drop-state'
      diagnostic('drop-not-live', id) if flags.include?('vacant')
      diagnostic('double-drop', id) if flags.include?('dropped')
    end
    return state unless flags.include?('live')
    # Whole-value arming and moves maintain correlation between a live flag
    # and initialized required bytes. Guarded cleanup reads only live paths.
    guarded = state.dup
    d[:required].each do |i|
      key = byte_key(root, off + i)
      raise BorrowRefused, 'drop flag initialization invariant is not established' unless state[key].include?('initialized')
      guarded[key] = ['initialized']
    end
    access(place, guarded, true, 'exclusive', width, d[:type])
    record_memory_loan_values(root, off, width, state)
    width.times do |i|
      key = byte_key(root, off + i)
      state[key] = if flags == ['live']
                     ['dropped']
                   else
                     (state[key].map { |s| s == 'initialized' ? 'dropped' : s } + ['dropped']).uniq.sort
                   end
    end
    state[drop_key(id)] = flags.map { |f| f == 'live' ? 'dropped' : f }.uniq.sort
    state
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
        frame = x[3] && try_frame(x[1])
        if frame
          # EDG's try block: if (_setjmp(frame.buffer) == 0) BODY else HANDLER. _setjmp returns 0 first, so the
          # handler is entered only from the throw points of the body, by the runtime's longjmp. Throws in the
          # handler go to the enclosing try blocks, so it is built outside this one.
          b = sequence(x[3].drop(1), follow, brk, cont)
          @try_stack.push([b, frame, declared_slots(x[2]), catch_all?(x[3].drop(1))])
          a = sequence(x[2].drop(1), follow, brk, cont)
          @try_stack.pop
          follow = node(['condition', x[1]], [a])
        elsif !x[3] && clause_test?(x[1])
          # The last typed clause of a handler's dispatch: the runtime longjmps only into a try whose catch table
          # matches, so __catch_clause_number names one of its clauses, and no match is not a path.
          follow = node(['condition', x[1]], [sequence(x[2].drop(1), follow, brk, cont)])
        else
          a = sequence(x[2].drop(1), follow, brk, cont)
          b = x[3] ? sequence(x[3].drop(1), follow, brk, cont) : follow
          follow = node(['condition', x[1]], [a, b])
        end
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
        # __throw and __rethrow do not return; any other throwing call also continues normally.
        follow = node(x, eh_noreturn?(x) ? [] : [follow])
        # A throw point reaches the handler of every enclosing try block of this function: which one catches
        # depends on the exception's type, which no summary states.
        if !@try_stack.empty? && throw_point?(x)
          targets = []
          @try_stack.reverse_each do |handler, frame, slots, all|
            targets << [handler, frame, slots]
            break if all # a catch (...) keeps the exception from the enclosing try blocks
          end
          @exc[follow] = targets
        end
      end
    end
    follow
  end

  EH_THROWS = %w[__throw __rethrow].freeze

  def direct_callee(x)
    return nil unless x.is_a?(Array)
    callee = bh(x) == 'call' ? x[2] : (bh(x) == 'call-borrow' ? x[4] : nil)
    callee.is_a?(IRSym) && callee.sig == '&' ? callee.name : nil
  end

  # A statement that calls __throw, __rethrow, or a callee whose summary may throw.
  def throw_point?(x)
    return false unless x.is_a?(Array)
    name = direct_callee(x)
    if name
      return true if EH_THROWS.include?(name)
      summary = @call_effects.lookup(name)
      return true if summary && summary[:throws]
    end
    x.any? { |y| throw_point?(y) }
  end

  def eh_noreturn?(x)
    bh(x) == 'eval' && EH_THROWS.include?(direct_callee(x[1]))
  end

  # The frame slot of a try block, when cond is (eq int R (const int 0)) with R the result of _setjmp on a pointer
  # into a local slot.
  def try_frame(cond)
    d = cond.is_a?(String) ? @register_defs[cond] : nil
    return nil unless d && d.length == 1 && bh(d[0]) == 'let' && d[0].length == 4
    e = d[0][3]
    return nil unless bh(e) == 'eq' && e.length == 4 && e[3] == ['const', 'int', '0'] && e[2].is_a?(String)
    r = @register_defs[e[2]]
    return nil unless r && r.length == 1 && bh(r[0]) == 'let' && r[0].length == 4
    call = r[0][3]
    return nil unless direct_callee(call) == '_setjmp' && call.length == 4
    root_slot(call[3])
  end

  # The local slot a pointer is derived from by constant offsets and casts, or nil.
  def root_slot(x)
    return x.name if x.is_a?(IRSym) && x.sig == '$'
    return root_slot(x[1]) if bh(x) == 'offset' && x.length == 3
    return root_slot(x[2]) if bh(x) == 'bitcast' && x.length == 3
    return nil unless x.is_a?(String) && x.start_with?('%')
    d = @register_defs[x]
    return nil unless d && d.length == 1 && bh(d[0]) == 'let' && d[0].length == 4
    root_slot(d[0][3])
  end

  # A handler catches every exception when it has no clause dispatch (catch (...) alone), or when its dispatch on
  # __catch_clause_number ends in a final else (a last catch (...)). A dispatch without one lets the runtime pass
  # other types on: pass 1 of __throw longjmps only into a try whose catch table matches.
  def catch_all?(stmts)
    dispatch = stmts.find { |y| bh(y) == 'if' && clause_test?(y[1]) }
    return true unless dispatch
    return false unless dispatch[3]
    catch_all?(dispatch[3].drop(1))
  end

  def clause_test?(cond)
    d = cond.is_a?(String) ? @register_defs[cond] : nil
    return false unless d && d.length == 1 && bh(d[0]) == 'let' && d[0].length == 4 && bh(d[0][3]) == 'eq'
    r = @register_defs[d[0][3][2]]
    r && r.length == 1 && bh(r[0]) == 'let' && r[0].length == 4 && bh(r[0][3]) == 'load' && eh_global?(r[0][3][2], '__catch_clause_number')
  end

  # The slots a statement subtree declares.
  def declared_slots(x)
    return [] unless x.is_a?(Array)
    own = bh(x) == 'decl' && x[1].is_a?(IRSym) && x[1].sig == '$' ? [x[1].name] : []
    (own + x.flat_map { |y| declared_slots(y) }).uniq
  end

  def diagnostic(code, place)
    msg = "#{@name}: #{code}: #{place}"
    msg += " at #{@cur_loc[0]}:#{@cur_loc[1]}" if @cur_loc
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
  # copying: a read that carries byte states instead of requiring them initialized.
  def access(place, state, read, borrowing = nil, width = nil, semantic_type = nil, copying = false)
    base = base_origin(place)
    return if base == 'eh' # the exception object: runtime storage, not caller memory
    if base == 'external'
      diagnostic('contract-not-closed', 'external memory') if @summary
      return
    end
    if base.start_with?('ended:')
      diagnostic('use-after-scope', base[6..-1])
      return
    end
    if base.start_with?('expired:')
      diagnostic('inactive-loan', base[8..-1])
      return
    end
    return ranged_access(place, state, read, borrowing, width, semantic_type) if ranged?(place)
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
    required = semantic_type ? semantic_bytes(name, off, semantic_type) : nil
    if required
      status = required.flat_map { |i| state[byte_key(name, off + i)] || ['dead'] }.uniq
    end
    diagnostic('uninitialized', label) if read && !copying && status.include?('uninitialized')
    diagnostic('use-after-move', label) if read && status.include?('moved')
    diagnostic('use-after-drop', label) if read && status.include?('dropped')
    @loans.each do |id, loan|
      next if id == own || (own && @ancestors[own].include?(id)) || loan[0] != name || !(state['loan:' + id] || []).include?('active')
      next unless overlaps(off, width, loan[3], loan[4])
      diagnostic('loan-conflict', label + ' (' + id + ')') if loan[1] == 'exclusive' || !read || borrowing == 'exclusive'
    end
    [name, off, width]
  end

  # An access at an unknown position of an array: every byte of the range must
  # allow it, and a write initializes none (a weak update).
  def ranged_access(place, state, read, borrowing, width, semantic_type)
    raise BorrowRefused, 'borrow through a dynamic index' if borrowing || semantic_type
    name, lo, n, own = array_range(base_origin(place))
    raise BorrowRefused, 'access through a dynamic index requires a width' unless width
    raise BorrowRefused, 'access wider than its array' if width > n
    if own
      ([own] + @ancestors[own]).each do |id|
        diagnostic('inactive-loan', id) unless state['loan:' + id] == ['active']
      end
      diagnostic('write-through-shared-loan', own) if !read && @loans[own][1] == 'shared'
    end
    label = lo == 0 && n == @slot_info[name][1] ? name : name + '[' + lo.to_s + '..' + (lo + n).to_s + ']'
    status = (0...n).flat_map { |i| state[byte_key(name, lo + i)] || ['dead'] }.uniq
    diagnostic('use-after-scope', label) if status.include?('dead')
    diagnostic('uninitialized', label) if read && status.include?('uninitialized')
    diagnostic('use-after-move', label) if read && status.include?('moved')
    diagnostic('use-after-drop', label) if read && status.include?('dropped')
    @loans.each do |id, loan|
      next if id == own || (own && @ancestors[own].include?(id)) || loan[0] != name || !(state['loan:' + id] || []).include?('active')
      next unless overlaps(lo, n, loan[3], loan[4])
      diagnostic('loan-conflict', label + ' (' + id + ')') if loan[1] == 'exclusive' || !read
    end
    nil
  end

  # EDG's lowered exception handling links frames, which are locals, from the
  # global @"__curr_eh_stack_entry". The runtime reads them only while unwinding,
  # and every call this checker accepts is nothrow, so the stack is a tracked
  # value: a function must leave it as it found it (the caller's frames).
  def eh_top?(x)
    x.is_a?(IRSym) && x.sig == '@' && x.name == '__curr_eh_stack_entry'
  end

  # The region counter (EDG's __eh_curr_region) says which frame objects are alive, for the runtime's unwinding. It is
  # scalar bookkeeping that the normal path updates around each object, not program memory.
  def eh_global?(x, name)
    x.is_a?(IRSym) && x.sig == '@' && x.name == name
  end

  def eh_region?(x)
    x.is_a?(IRSym) && x.sig == '@' && x.name == '__eh_curr_region'
  end

  def check_eh_stack(state)
    top = state['value:@eh'] || ['external']
    return if top == ['external']
    left = top.reject { |p| p == 'external' }.map { |p| b = base_origin(p); b.start_with?('ended:') ? b[6..-1] : (storage(p) || b) }
    diagnostic('eh-frame-not-popped', left.uniq.sort.join(','))
  end

  # (copy N DST SRC) moves byte states and the pointer values wholly inside the
  # range from SRC to DST. External memory reads as initialized bytes without
  # pointer provenance; a local address may not be copied into it.
  def copy_memory(x, state)
    n = constant_offset(x[1])
    raise BadIR, 'negative copy length' if n < 0
    src = value(x[3], state)
    dst = value(x[2], state)
    if src.empty? || dst.empty? || (src + dst).include?('unknown')
      raise BorrowRefused, 'copy with unknown pointer provenance'
    end
    raise BorrowRefused, 'copy through an aliased place' unless src.length == 1 && dst.length == 1
    raise BorrowRefused, 'copy through a dynamic index' if ranged?(src[0]) || ranged?(dst[0])
    bytes = Array.new(n) { ['initialized'] }
    pointers = []
    if %w[external eh].include?(base_origin(src[0]))
      access(src[0], state, true, nil, n)
    else
      a = access(src[0], state, true, nil, n, nil, true)
      return unless a
      root, off, = a
      raise BorrowRefused, 'copy of drop-obligated storage requires a copy contract' if @drops.values.any? { |d| d[:root] == root && overlaps(off, n, d[:off], d[:width]) }
      record_memory_loan_values(root, off, n, state)
      bytes = (0...n).map { |i| (state[byte_key(root, off + i)] || ['dead']).map { |b| b == 'dead' ? 'uninitialized' : b }.uniq.sort }
      prefix = 'pointer:' + @slot_info[root][0].to_s + ':'
      state.each do |key, v|
        next unless key.start_with?(prefix)
        parts = key.split(':')
        o, w = parts[2].to_i, parts[3].to_i
        pointers << [o - off, w, v] if o >= off && o + w <= off + n
      end
    end
    if %w[external eh].include?(base_origin(dst[0]))
      access(dst[0], state, false, nil, n)
      if pointers.any? { |_o, _w, v| v.any? { |p| p != 'external' } }
        raise BorrowRefused, 'copy into external storage may escape a local address'
      end
      return
    end
    a = access(dst[0], state, false, nil, n)
    return unless a
    root, off, = a
    raise BorrowRefused, 'copy into drop-obligated storage requires a copy contract' if @drops.values.any? { |d| d[:root] == root && overlaps(off, n, d[:off], d[:width]) }
    if @regions.values.any? { |r| r[:name] == root }
      raise BorrowRefused, 'copy of unknown pointer provenance into argument memory' if pointers.any? { |_o, _w, v| v.include?('unknown') }
      diagnostic('contract-escape', root) if pointers.any? { |_o, _w, v| v.any? { |p| p != 'external' } }
    end
    forget_pointer_values(root, off, n, state)
    n.times do |i|
      key = byte_key(root, off + i)
      state[key] = bytes[i] unless (state[key] || ['dead']).include?('dead')
    end
    pointers.each { |o, w, v| state[pointer_key(root, off + o, w)] = v }
  end

  def invalidate_pointers(state, from, to)
    state.keys.each do |entry|
      if entry.start_with?('value:') || entry.start_with?('pointer:')
        state[entry] = state[entry].map { |p| from.include?(base_origin(p)) ? to : p }.uniq
      end
    end
  end

  def storage(place)
    return array_range(base_origin(place))[0] if ranged?(place)
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

  def record_memory_loan_values(root, off, width, state)
    prefix = 'pointer:' + @slot_info[root][0].to_s + ':'
    state.each do |key, values|
      next unless key.start_with?(prefix)
      parts = key.split(':')
      record_loan_values(values) if overlaps(off, width, parts[2].to_i, parts[3].to_i)
    end
  end

  def scalar_abi_class(ty)
    return 's' if ty == 'float'
    return 'd' if ty == 'double'
    return nil unless ty.is_a?(String) && BorrowLayouts::PRIMITIVES.key?(ty)
    BorrowLayouts::PRIMITIVES[ty] <= 4 ? 'w' : 'l'
  end

  def check_memory_argument_abi(arg)
    return if arg.is_a?(IRSym)
    return check_memory_argument_abi(arg[1]) if bh(arg) == 'offset'
    actual = @register_types[arg] || []
    unless !actual.empty? && actual.all? { |t| bh(t) == 'ptr' || scalar_abi_class(t) == 'l' }
      raise BorrowRefused, 'memory call argument does not have a pointer ABI class'
    end
  end

  def check_value_argument(arg, ty)
    actual = bh(arg) == 'const' ? [arg[1]] : (@register_types[arg] || [])
    if actual.empty? || actual.any? { |t| scalar_abi_class(t) != scalar_abi_class(ty) }
      raise BorrowRefused, 'value call argument ABI class disagrees with its contract'
    end
  end

  def apply_call_output(root, off, width, ty, state, initialize)
    required = semantic_bytes(root, off, ty) || (0...width).to_a
    mask = {}
    required.each { |i| mask[i] = true }
    forget_pointer_values(root, off, width, state)
    width.times do |i|
      key = byte_key(root, off + i)
      if mask[i]
        state[key] = state[key].map { |v| v == 'dead' ? v : 'initialized' }.uniq.sort if initialize
      else
        # A typed mutation/construction does not promise to preserve or define
        # padding, even when the caller had initialized those bytes earlier.
        state[key] = state[key].map { |v| v == 'dead' ? v : 'uninitialized' }.uniq.sort
      end
    end
  end

  def refuse_live_drops(state)
    live = @drops.keys.select { |id| (state[drop_key(id)] || []).include?('live') }
    raise BorrowRefused, 'throwing calls with live drop obligations require cleanup contracts' unless live.empty?
  end

  # EDG's exception runtime (lib_src/throw.c), whose protocol the checker knows by name, like its globals:
  #   _setjmp(buf)                 the try block's first return (0); the handler is entered by exceptional edges
  #   __throw(), __rethrow()       throw points that do not return
  #   __throw_setup*(ti, size, f)  the exception object: provenance eh, storage of the runtime
  #   __exception_caught()         bookkeeping
  #   __destroy_exception_object() ends the caught object: pointers to it become dangling
  # Returns nil for any other callee.
  def eh_runtime_call(x, state)
    name = x[2].name
    args = x.drop(3)
    case name
    when '_setjmp'
      raise BadIR, '_setjmp form' unless args.length == 1
      v = value(args[0], state)
      raise BorrowRefused, '_setjmp requires a local frame buffer' unless v.length == 1 && address(v[0])
      []
    when '__exception_caught'
      raise BadIR, "#{name} form" unless args.empty?
      []
    when '__destroy_exception_object'
      raise BadIR, "#{name} form" unless args.empty?
      invalidate_pointers(state, ['eh'], 'ended:exception object')
      []
    when '__throw', '__rethrow'
      raise BadIR, "#{name} form" unless args.empty?
      refuse_live_drops(state)
      @throws = true
      []
    when '__throw_setup', '__throw_setup_dtor', '__throw_setup_ptr'
      args.each do |a|
        v = value(a, state)
        raise BorrowRefused, 'exception setup with a local address' if v.any? { |p| p != 'external' }
      end
      ['eh']
    end
  end

  def apply_call(x, state, returned_id = nil)
    unless x.length >= 3 && x[2].is_a?(IRSym) && x[2].sig == '&'
      raise BorrowRefused, 'contracted calls require direct function symbols'
    end
    eh = eh_runtime_call(x, state)
    return eh if eh
    summary = @call_effects.lookup(x[2].name)
    raise BorrowRefused, 'calls require lifetime/effect contracts' unless summary
    if summary[:throws] && x[2].name != @name
      # Unwinding out of this function is not a path: the runtime runs the destructors of its frames (the same
      # destructors the normal path checks at scope end), and every local dies with it. An enclosing try block of
      # this function gets an exceptional edge instead (sequence). Obligations that only a destructor frame would
      # discharge are refused.
      refuse_live_drops(state)
      @throws = true
    end
    raise BadIR, 'call return type disagrees with its effect contract' unless same_type?(x[1], summary[:result])
    returned_id ||= @implicit_loans[x.object_id] if summary[:alias]
    raise BorrowRefused, 'returned aliases require call-borrow' if summary[:alias] && !returned_id
    args = x.drop(3)
    raise BadIR, 'call arity disagrees with its effect contract' unless args.length == summary[:args].length
    resolved = []
    args.each_with_index do |arg, i|
      mode, ty = summary[:args][i]
      if bh(arg) == 'sret'
        # (sret T PLACE): the caller's buffer for an aggregate result, which the callee initializes.
        raise BadIR, 'sret argument form' unless arg.length == 3
        raise BadIR, 'sret argument disagrees with its effect contract' unless mode == 'init' && same_type?(arg[1], ty)
        arg = arg[2]
      elsif bh(arg) == 'byval'
        # (byval T PLACE): the callee gets its own copy, a read of the caller's object.
        raise BadIR, 'byval argument form' unless arg.length == 3
        unless mode == 'byval' && same_type?(arg[1], ty)
          raise BadIR, 'by-value call argument disagrees with its effect contract'
        end
        arg = arg[2]
        mode = 'read'
      elsif mode == 'byval'
        raise BadIR, 'by-value contract argument passed by address'
      end
      origins = value(arg, state)
      if mode == 'value'
        raise BorrowRefused, 'value call argument carries pointer provenance' unless origins.empty?
        check_value_argument(arg, ty)
        resolved << [mode, ty, []]
        next
      end
      # A pointer to ended storage or through an ended loan is an error at the call.
      dead = origins.select { |p| b = base_origin(p); b.start_with?('ended:') || b.start_with?('expired:') }
      dead.each { |p| access(p, state, true) }
      origins -= dead
      if origins.empty? && !dead.empty?
        resolved << [mode, ty, []]
        next
      end
      if origins.include?('eh')
        # The exception object is the runtime's storage, which the checker does not track (its constructor, say).
        raise BorrowRefused, 'call argument that may be the exception object or a local place' unless origins == ['eh']
        resolved << [mode, ty, []]
        next
      end
      raise BorrowRefused, 'memory call arguments require known local provenance' if origins.empty? || origins.any? { |p| !address(p) }
      check_memory_argument_abi(arg)
      if mode != 'read' && origins.length != 1
        raise BorrowRefused, 'mutating call arguments require one known local place'
      end
      places = origins.map do |p|
        root, off, own = address(p)
        width = type_width(ty, root, off)
        check_range(root, off, width)
        semantic_bytes(root, off, ty)
        [p, root, off, width, own]
      end
      resolved << [mode, ty, places]
    end
    # Summaries do not prescribe an evaluation order within the callee. Reject
    # overlapping mutation footprints before any postcondition can initialize,
    # overwrite, or consume memory that another argument still needs.
    resolved.each_with_index do |left, i|
      resolved.drop(i + 1).each do |right|
        next if left[0] == 'read' && right[0] == 'read'
        left[2].each do |a|
          right[2].each do |b|
            if a[1] == b[1] && overlaps(a[2], a[3], b[2], b[3])
              raise BorrowRefused, 'overlapping mutating call arguments require an aliasing contract'
            end
          end
        end
      end
    end
    resolved.each do |mode, ty, places|
      places.each do |origin, root, off, width, own|
        case mode
        when 'read'
          access(origin, state, true, nil, width, ty)
          record_memory_loan_values(root, off, width, state)
        when 'write'
          # A mutation requires an existing initialized value and preserves its
          # ownership identity; its resulting pointer contents are unknown.
          access(origin, state, true, 'exclusive', width, ty)
          record_memory_loan_values(root, off, width, state)
          # The access is mutable even when its input representation is read.
          if own && @loans[own][1] == 'shared'
            diagnostic('write-through-shared-loan', own)
          end
          apply_call_output(root, off, width, ty, state, false)
        when 'init'
          access(origin, state, false, nil, width, ty)
          track_drop_write(root, off, width, state)
          apply_call_output(root, off, width, ty, state, true)
        when 'consume'
          raise BorrowRefused, 'consume calls require an unborrowed owned place' if own
          match = @drops.find do |id, d|
            d[:root] == root && d[:off] == off && d[:width] == width && same_type?(d[:type], ty)
          end
          raise BorrowRefused, 'consume call has no matching drop obligation' unless match
          drop_event(['drop-state', IRStr.new(match[0].bytes)], state)
        end
      end
    end
    return [] unless returned_id
    loan = @loans[returned_id]
    a = summary[:alias]
    sources = resolved[a[:arg]][2]
    raise BorrowRefused, 'returned alias requires one known source place' unless sources.length == 1
    origin = sources[0][0]
    parent = loan[2]
    if parent && base_origin(origin) != 'loan:' + parent
      raise BorrowRefused, 'returned alias source must preserve declared parent identity'
    end
    projected = project(origin, a[:offset])
    actual = address(projected)
    unless actual && actual[0] == loan[0] && actual[1] == loan[3] && (parent || actual[2].nil?)
      raise BorrowRefused, 'returned alias source does not match its declared range'
    end
    record_loan_definition(returned_id)
    diagnostic('loan-already-active', returned_id) if state['loan:' + returned_id].include?('active')
    diagnostic('exclusive-reborrow-of-shared', returned_id) if parent && loan[1] == 'exclusive' && @loans[parent][1] == 'shared'
    access(projected, state, true, loan[1], loan[4], loan[5])
    state['loan:' + returned_id] = ['active']
    ['loan:' + returned_id]
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
    when 'null'
      # A null pointer names no place: dereferencing a value that can only be
      # null is refused for lack of provenance, and a join adds nothing for it.
      raise BadIR, 'null form' unless x.length == 2 && bh(x[1]) == 'ptr'
      []
    when 'move-value', 'copy-value'
      raise BadIR, "#{bh(x)} form" unless x.length == 3
      borrow_scalar_type!(x[1])
      place = direct_place(x[2])
      raise BorrowRefused, 'value transfers require direct local slots or constant field offsets' unless place
      name, off = place
      raise BadIR, "value transfer refers to unknown slot #{name}" unless @slots[name]
      width = type_width(x[1])
      moving = bh(x) == 'move-value'
      track_drop_transfer(name, off, width, x[1], moving, state)
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
      access(project('local:' + loan[0], loan[3]), state, true, loan[1], loan[4], loan[5])
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
        raise BorrowRefused, 'reborrow through a dynamic index' if ranged?(p)
        a = address(p)
        raise BorrowRefused, 'reborrow source offset does not match its declared range' if a && a[1] != loan[3]
        access(p, state, true, loan[1], loan[4], loan[5])
      end
      state['loan:' + id] = ['active']
      ['loan:' + id]
    when 'offset'
      raise BadIR, 'offset form' unless x.length == 3
      delta = constant_offset(x[2])
      value(x[1], state).map { |p| project(p, delta) }.uniq
    when 'index'
      raise BadIR, 'index form' unless x.length == 4
      size = constant_offset(x[3])
      bases = value(x[1], state)
      raise BorrowRefused, 'pointer arithmetic requires place projections' if bases.empty?
      if bh(x[2]) == 'const'
        raise BadIR, 'index constant form' unless x[2].length == 3
        delta = constant_offset(x[2][2]) * size
        bases.map { |p| project(p, delta) }.uniq
      else
        raise BorrowRefused, 'pointer-valued index' unless value(x[2], state).empty?
        bases.map { |p| ranged(p) }.uniq
      end
    when 'load'
      borrow_scalar_type!(x[1])
      return record_loan_values(state['value:@eh'] || ['external']) if eh_top?(x[2]) && bh(x[1]) == 'ptr'
      return [] if eh_region?(x[2]) || eh_global?(x[2], '__catch_clause_number')
      return ['eh'] if eh_global?(x[2], '__caught_object_address') && bh(x[1]) == 'ptr'
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
    when 'call-borrow'
      apply_call(['call', x[1], x[4]] + x.drop(5), state, bname(x[2]))
    when 'call'
      apply_call(x, state)
    else
      # Arithmetic on addresses would erase provenance. Restrict this first
      # increment to scalar arithmetic and conversions on non-pointer values.
      # Scalar operations, integer and floating, and the conversions between them. The checked conversions (cf2i)
      # trap on NaN or an out-of-range value; a trap is not a memory access, so it is not modeled here.
      allowed = %w[wadd wsub wmul wneg cadd csub cmul cdiv crem cshl cshr cneg and or xor not eq ne lt.s lt.u le.s le.u gt.s gt.u ge.s ge.u
                   fadd fsub fmul fdiv fneg lt.f le.f gt.f ge.f iconv cf2i i2f u2f fconv]
      raise BorrowRefused, "expression #{bh(x)}" unless allowed.include?(bh(x))
      # Comparing addresses reads no memory and its result has no provenance.
      if bh(x[1]) == 'ptr' && %w[eq ne lt.u le.u gt.u ge.u].include?(bh(x))
        raise BadIR, "#{bh(x)} form" unless x.length == 4
        x.drop(2).each { |v| value(v, state) }
        return []
      end
      raise BorrowRefused, 'pointer conversion requires provenance' if bh(x[1]) == 'ptr'
      vals = x.drop(2).flat_map { |v| value(v, state) }
      raise BorrowRefused, 'pointer arithmetic/conversion requires place projections' unless vals.empty?
      []
    end
  end

  def transfer(x, state)
    @cur_loc = @locs[x.object_id]
    arities = {'join'=>[1], 'function-exit'=>[1], 'drop-live'=>[2], 'drop-state'=>[2], 'drop-state-if-live'=>[2], 'unreachable'=>[1], 'decl'=>[3], 'scope-end'=>[2],
               'let'=>[4], 'set'=>[3, 4], 'store'=>[4], 'return'=>[1,2],
               'condition'=>[2], 'eval'=>[2], 'nonnull'=>[2], 'bounds'=>[3], 'rref-arg'=>[2], 'loan-end'=>[2], 'zero-fill'=>[3], 'copy'=>[4]}
    sizes = arities[bh(x)]
    raise BadIR, "#{bh(x)} form" if sizes && !sizes.include?(x.length)
    case bh(x)
    when 'function-exit'
      check_eh_stack(state)
      check_contract_exit(state) if @summary
      check_pending_drops(state)
    when 'drop-live', 'drop-state', 'drop-state-if-live'
      return drop_event(x, state)
    when 'join', 'unreachable', 'loc'
      # Locations are preserved in input; diagnostics currently identify functions and slots.
    when 'decl'
      raise BadIR, 'decl form' unless x.length == 3 && %w[val ref param temp].include?(x[2])
      k = key(x[1])
      if k && k.start_with?('slot:')
        name = k[5..-1]
        raise BadIR, "undeclared slot #{name}" unless @slots[name]
        check_pending_drops(state, name)
        reset_storage(name, state, 'uninitialized')
        reset_drop_flags(name, state, 'vacant')
      end
    when 'scope-end'
      k = key(x[1])
      k = 'slot:' + @byval[k] if k && @byval[k] # (scope-end %N) ends a by-value parameter's copy
      raise BadIR, 'scope-end requires a local slot' unless k && k.start_with?('slot:')
      name = k[5..-1]
      raise BadIR, "unknown local slot #{name}" unless @slots[name]
      check_pending_drops(state, name)
      reset_storage(name, state, 'dead', false)
      reset_drop_flags(name, state, 'dead')
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
      raise BadIR, "contract argument loan #{id} cannot end inside the call" if contract_loan?(id)
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
      # (set %N OPERAND) reassigns a register its (let ...) typed.
      borrow_scalar_type!(x[2]) if x.length == 4
      v = value(x[-1], state)
      raise BadIR, 'register destination' unless x[1].is_a?(String) && x[1].start_with?('%')
      state['value:' + x[1]] = v
    when 'store', 'zero-fill'
      zero = bh(x) == 'zero-fill'
      borrow_scalar_type!(x[1]) unless zero
      width = zero ? constant_offset(x[1]) : type_width(x[1])
      raise BadIR, 'negative zero-fill length' if width < 0
      v = zero ? nil : value(x[3], state)
      return state if eh_region?(x[2]) && !zero
      if !zero && eh_top?(x[2]) && bh(x[1]) == 'ptr'
        # Pushing or popping a frame of EDG's exception-handling stack.
        raise BorrowRefused, 'exception-stack entry of unknown provenance' if v.empty? || v.include?('unknown')
        state['value:@eh'] = v
        return state
      end
      dest = value(x[2], state)
      dest.each { |p| access(p, state, false, nil, width) }
      if dest == ['external'] || dest == ['eh']
        # External memory and the exception object are not tracked; only a local address can escape into them.
        if v && v.any? { |p| p != 'external' && !(p == 'eh' && dest == ['eh']) }
          raise BorrowRefused, 'store into the exception object may escape a local address' if dest == ['eh']
          raise BorrowRefused, 'store through external storage may escape a local address'
        end
        return state
      end
      raise BorrowRefused, 'store through external storage may escape a local address' if dest.any? { |p| %w[external eh].include?(base_origin(p)) }
      raise BorrowRefused, 'store through an aliased destination' unless dest.length == 1
      if ranged?(dest[0])
        raise BorrowRefused, 'pointer store through a dynamic index' if !zero && bh(x[1]) == 'ptr'
        root, lo, n, = array_range(base_origin(dest[0]))
        raise BorrowRefused, 'store through a dynamic index into drop-obligated storage' if @drops.values.any? { |d| d[:root] == root }
        forget_pointer_values(root, lo, n, state)
        return state
      end
      a = address(dest[0])
      return state unless a
      if v && @regions.values.any? { |r| r[:name] == a[0] }
        raise BorrowRefused, 'store of unknown pointer provenance into argument memory' if v.include?('unknown')
        diagnostic('contract-escape', a[0]) if v.any? { |p| p != 'external' }
      end
      track_drop_write(a[0], a[1], width, state)
      write_memory(a[0], a[1], width, state, !zero && bh(x[1]) == 'ptr' ? v : nil)
    when 'return'
      check_eh_stack(state)
      refs = x[1] ? value(x[1], state) : []
      raise BorrowRefused, 'return with unknown pointer provenance' if refs.include?('unknown')
      if @summary
        check_contract_return(refs)
        check_contract_exit(state)
      end
      refs.each do |p|
        next if p == 'external'
        raise BorrowRefused, 'returning the address of an exception object' if p == 'eh'
        # Argument pointers are checked against the returned alias contract.
        next if @regions.values.any? { |r| r[:name] == storage(p) }
        if p.start_with?('expired:')
          diagnostic('inactive-loan', p[8..-1])
        else
          diagnostic('return-local-address', base_origin(p).start_with?('ended:') ? base_origin(p)[6..-1] : storage(p))
        end
      end
      check_pending_drops(state)
    when 'copy'
      copy_memory(x, state)
    when 'condition', 'eval', 'nonnull'
      value(x[1], state)
    when 'bounds'
      raise BorrowRefused, 'pointer-valued index' unless value(x[1], state).empty?
      value(x[2], state)
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
    @drops.each_key { |id| initial[drop_key(id)] = ['dead'] }
    @params.each do |p, name, pointer|
      initial['value:' + p] = pointer ? ['external'] : []
      if @byval[p]
        reset_storage(@byval[p], initial, 'initialized')
        initial['value:' + p] = ['local:' + @byval[p]]
      end
      if @slots[name]
        reset_storage(name, initial, 'uninitialized')
        reset_drop_flags(name, initial, 'vacant')
      end
    end
    @loans.each_key { |id| initial['loan:' + id] = ['inactive'] }
    initial['value:@eh'] = ['external']
    @regions.each do |reg, r|
      name = r[:name]
      r[:width].times { |i| initial[byte_key(name, i)] = ['uninitialized'] }
      unless r[:mode] == 'init'
        r[:required].each { |i| initial[byte_key(name, i)] = ['initialized'] }
      end
      if r[:mode] == 'consume'
        initial['value:' + reg] = ['local:' + name]
        initial[drop_key(name)] = ['live']
      else
        initial['value:' + reg] = ['loan:' + name]
        initial['loan:' + name] = ['active']
      end
    end
    initial
  end

  def contract_loan?(id)
    @regions.values.any? { |r| r[:name] == id && r[:mode] != 'consume' }
  end

  def expire_dead_loans(state, needed)
    @loans.each_key do |id|
      status = state['loan:' + id]
      next if needed.include?(id) || contract_loan?(id) || !status.include?('active')
      state['loan:' + id] = status.map { |s| s == 'active' ? 'inferred-ended' : s }.uniq.sort
      invalidate_pointers(state, ['loan:' + id], 'expired:' + id)
    end
    state
  end

  def join_states(old, edge)
    merged = edge.dup
    (old.keys + edge.keys).uniq.each do |k|
      # Missing register definitions cannot acquire provenance from just
      # one predecessor. Slot entries exist on every path.
      a = old[k] || ['unknown']
      b = edge[k] || ['unknown']
      merged[k] = (a + b).uniq.sort
      merged[k] = widen(merged[k]) if k.start_with?('value:') || k.start_with?('pointer:')
    end
    merged
  end

  # The state at a handler's entry, from the states before and after a throwing call: the callee may have applied
  # any part of its effects. Unwinding destroyed the objects declared in the try body (their destructors are the ones
  # the normal path checks at scope end), and the runtime's longjmp leaves the try's frame on top of the stack.
  def unwind_to(state, frame, slots)
    state = state.dup
    slots.each do |name|
      next unless @slots[name]
      reset_storage(name, state, 'dead', false)
      reset_drop_flags(name, state, 'dead')
      origins = ['local:' + name]
      @loans.each do |id, loan|
        next unless loan[0] == name
        origins << 'loan:' + id
        state['loan:' + id] = ['ended']
      end
      invalidate_pointers(state, origins, 'ended:' + name)
    end
    state['value:@eh'] = ['local:' + frame]
    state
  end

  def solve(expire = false)
    incoming = { @entry => initial_state }
    queue = [@entry]
    flow = lambda do |succ, edge|
      old = incoming[succ]
      merged = old ? join_states(old, edge) : edge.dup
      if old != merged
        incoming[succ] = merged
        queue << succ unless queue.include?(succ)
      end
    end
    until queue.empty?
      id = queue.shift
      out = transfer(@nodes[id][0], incoming[id].dup)
      @nodes[id][1].each do |succ|
        flow.call(succ, expire ? expire_dead_loans(out.dup, @needed[succ]) : out)
      end
      (@exc[id] || []).each do |handler, frame, slots|
        edge = unwind_to(join_states(incoming[id], out), frame, slots)
        flow.call(handler, expire ? expire_dead_loans(edge, @needed[handler]) : edge)
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
        succs = @nodes[id][1] + (@exc[id] || []).map(&:first)
        after = succs.flat_map { |succ| @needed[succ] }.uniq
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
    # A summary that says nothrow must not describe a body that calls a throwing callee.
    diagnostic('contract-may-throw', @name) if @summary && @throws && !@summary[:throws]
  end
end

def form_text(x)
  return '(' + x.map { |y| form_text(y) }.join(' ') + ')' if x.is_a?(Array)
  return x.sig + form_text(IRStr.new(x.name.bytes)) if x.is_a?(IRSym)
  return x unless x.is_a?(IRStr)
  out = '"'
  x.codes.each do |c|
    out << if c == 34 || c == 92
             92.chr + c.chr
           elsif c >= 32 && c < 127
             c.chr
           else
             format('\\%03o', c)
           end
  end
  out + '"'
end

# Opt-in summary inference. Each defined function other than main without a
# summary gets the first candidate summary its body verifies against, so its
# callers can be checked without hand-written contracts. Callees are searched first, and a
# self-recursive call uses the candidate itself as its hypothesis. Mutually
# recursive functions get no summary. Every inferred summary is re-verified when
# its function is checked, so inference cannot make a body pass that fails.
class SummaryInference
  attr_reader :effects, :inferred

  def initialize(functions, layouts, effects, infer_loan_ends, abi_sizes = {})
    @abi_sizes = abi_sizes
    @functions = {}
    functions.each { |f| @functions[bname(f[1])] = f }
    @layouts = layouts
    @effects = effects
    @infer_loan_ends = infer_loan_ends
    @inferred = []
    @callees = {}
    @functions.each do |name, f|
      @callees[name] = []
      collect = lambda do |x|
        if x.is_a?(IRSym) && x.sig == '&' && @functions.key?(x.name)
          @callees[name] << x.name unless @callees[name].include?(x.name)
        elsif x.is_a?(Array)
          x.each { |y| collect.call(y) }
        end
      end
      collect.call(f.drop(4))
    end
    order = []
    seen = {}
    visit = lambda do |name|
      next if seen[name]
      seen[name] = true
      @callees[name].each { |c| visit.call(c) }
      order << name
    end
    @functions.each_key { |name| visit.call(name) }
    order.each do |name|
      next if @effects.lookup(name) || name == 'main'
      form = search(@functions[name])
      next unless form
      @effects = @effects.with(name, form)
      @inferred << form
    end
  end

  # Width and alignment of a memory argument type, or nil if no contract can name it.
  def memory_type(ty)
    return nil if ty == 'void'
    return nil if bh(ty) == 'struct' && !@layouts.lookup(ty)
    return nil unless BorrowLayouts::PRIMITIVES.key?(ty) || bh(ty) == 'ptr' || bh(ty) == 'struct' || bh(ty) == 'array'
    @layouts.field_type(ty, [])
  rescue BorrowRefused, BadIR
    nil
  end

  def search(f)
    name = bname(f[1])
    ret = f[2][1]
    params = f[3].drop(1)
    slots = []
    params.each do |p|
      if bh(p) == 'sret'
        # The result buffer: initialized by the callee, its one choice is init.
        desc = memory_type(p[2])
        return nil unless desc
        slots << [p[1], p[2], desc, 'sret']
        next
      end
      ty = unconst(p[3]) # a const pointer parameter, such as a destructor's this
      if bh(ty) == 'byval'
        return nil unless bh(ty[1]) == 'struct' && @layouts.lookup(ty[1])
        slots << [p[1], ty[1], nil, 'byval']
      elsif bh(ty) == 'ptr'
        pointee = unconst(ty[1])
        desc = memory_type(pointee)
        return nil unless desc
        slots << [p[1], pointee, desc]
      elsif ty.is_a?(String) && BorrowLayouts::PRIMITIVES.key?(ty)
        slots << [p[1], ty, nil]
      else
        return nil
      end
    end
    aliases = [nil]
    if bh(ret) == 'ptr'
      result = memory_type(unconst(ret[1]))
      return nil unless result
      readonly = bh(ret[1]) == 'const'
      aliases = []
      slots.each_with_index do |(_reg, _ty, desc), i|
        next unless desc
        0.step(desc[:size] - result[:size], result[:align]) { |off| aliases << [i, off, readonly] }
      end
    elsif !(ret == 'void' || BorrowLayouts::PRIMITIVES.key?(ret))
      return nil
    end
    aliases.each do |a|
      form = search_modes(f, name, ret, slots, a)
      return form if form
    end
    nil
  end

  # Start every memory argument at the weakest effect and advance only the
  # arguments that diagnostics blame, until the body verifies or a choice runs out.
  def search_modes(f, name, ret, slots, a)
    choices = slots.each_with_index.map do |(_reg, _ty, desc, kind), i|
      if kind == 'byval'
        [['byval']]
      elsif kind == 'sret'
        [['init']]
      elsif desc.nil?
        [['value']]
      elsif a && a[0] == i && a[2]
        # A pointer to const grants no writes through the result.
        [%w[read shared], %w[write shared]]
      elsif a && a[0] == i
        # A pointer to non-const lets the caller write through the result.
        [%w[write exclusive], %w[read shared], %w[write shared]]
      else
        [['read'], ['init'], ['write']]
      end
    end
    index = Array.new(slots.length, 0)
    while true
      returns = ['returns', ret]
      args = slots.each_with_index.map { |(_reg, ty, _desc), i| [choices[i][index[i]][0], ty] }
      if a
        returns << ['from-arg', a[0].to_s, a[1].to_s, choices[a[0]][index[a[0]]][1]]
      end
      # Verified as may-throw, so a throwing body is not a contract violation. The final form says what the
      # body does: may-throw when it calls a throwing callee (other than itself), else nothrow.
      form = ['call-effects', IRStr.new(name.bytes), returns, ['may-throw'], ['noescape'], ['closed'], ['args'] + args]
      begin
        candidate = @effects.with(name, form)
        checker = LocalLifetime.new(f, @infer_loan_ends, @layouts, candidate, @abi_sizes)
        checker.run
      rescue BorrowRefused, BadIR
        return nil
      end
      if checker.errors.empty?
        form[3] = [checker.throws ? 'may-throw' : 'nothrow']
        return form
      end
      blamed = []
      checker.errors.each do |e|
        place = e.split(': ', 3)[2]
        reg = place && place.start_with?('*%') ? place[1..-1].split(/[\[ ]/)[0] : nil
        i = reg ? slots.index { |slot| slot[0] == reg } : nil
        return nil unless i
        blamed << i unless blamed.include?(i)
      end
      blamed.each do |i|
        index[i] += 1
        return nil if index[i] >= choices[i].length
      end
    end
  end
end

begin
  args = ARGV.dup
  infer = false
  summaries = false
  effect_files = []
  while args[0] && args[0].start_with?('--')
    option = args.shift
    if option == '--infer-loan-ends'
      infer = true
    elsif option == '--effects'
      raise BadIR, '--effects requires a file' unless args[0]
      effect_files << args.shift
    elsif option == '--infer-summaries'
      summaries = true
    else
      raise BadIR, "unknown option #{option}"
    end
  end
  unless args.length == 1
    raise BadIR, 'usage: scripts/mrb scripts/pathb-borrowck.rb [--infer-loan-ends] [--infer-summaries] [--effects FILE]... FILE.ir'
  end
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
  # --effects FILE: trusted (call-effects ...) forms for functions the module
  # does not describe itself, such as runtime helpers (scripts/pathb-runtime.effects).
  own = {}
  forms.each { |f| own[f[1].to_s] = true if bh(f) == 'call-effects' && f[1].is_a?(IRStr) }
  extra = []
  effect_files.each do |path|
    text = File.read(path).split("\n").reject { |l| l.lstrip.start_with?(';') }.join("\n")
    parse_forms(tokenize(text)).each do |f|
      raise BadIR, "#{path}: only call-effects forms are allowed" unless bh(f) == 'call-effects' && f[1].is_a?(IRStr)
      next if own[f[1].to_s]
      own[f[1].to_s] = true
      extra << f
    end
  end
  semantic_layouts = BorrowLayouts.new(forms, BadIR, BorrowRefused)
  # A file summary this module cannot state (its layouts are absent, say) is dropped rather than refusing the module:
  # a call the module makes to it is then refused at the call. A malformed file is still an error.
  extra = extra.select do |f|
    BorrowCallEffects.new([f], semantic_layouts, BadIR, BorrowRefused)
    true
  rescue BorrowRefused
    false
  end
  call_effects = BorrowCallEffects.new(forms + extra, semantic_layouts, BadIR, BorrowRefused)
  functions = forms.select { |f| bh(f) == 'function' }
  raise BorrowRefused, 'no functions to analyze' if functions.empty?
  # (abi-type "N" SIZE ALIGN ...) gives the size of a by-value aggregate parameter.
  abi_sizes = {}
  forms.each do |f|
    next unless bh(f) == 'abi-type' && f.length >= 3 && f[1].is_a?(IRStr) && f[2].is_a?(String)
    abi_sizes[f[1].to_s] = f[2].to_i if f[2].bytes.all? { |c| c >= 48 && c <= 57 }
  end
  if summaries
    inference = SummaryInference.new(functions, semantic_layouts, call_effects, infer, abi_sizes)
    call_effects = inference.effects
    inference.inferred.each { |form| puts 'inferred: ' + form_text(form) }
  end
  errors = []
  functions.each do |f|
    checker = LocalLifetime.new(f, infer, semantic_layouts, call_effects, abi_sizes)
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
