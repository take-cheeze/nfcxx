# frozen_string_literal: true

require 'set'

# ARMS_COMPLETE_ELSE: an owner call that is the else of exact-class arms covering every receiver that can answer its
# name becomes the proven nomethod.
#
# Sound because the owner set names every class that answers the name (NAME_OWNER_SET), so a receiver that answers
# it is an instance (singleton class included) of a listed owner K or of a subclass of K. So the else can only raise
# when, for every owner K, each class C in K's closed subclass set (arms_complete_subclasses: K and every class below
# it, native and dynamic subclasses included, or nil) has an arm on the path to the else that takes every instance
# of C:
#   - kind_of(K), or kind_of(C) (looks at the ancestors, singleton class included);
#   - an exact test that looks past a singleton class (bc2cpp_class_is, bc2cpp_obj_class);
#   - an exact test of the raw class pointer (`mrb_obj_ptr(r)->c ==`, `mrb_class(M, r) ==`), which a singleton
#     instance fails, only when ClosedWorld#exact_instances_singleton_free? holds: then only class objects and fresh
#     Object.new instances get one, and those answer only through Object/Module/Class, which never close here.
# A module owner needs its own kind_of arm; Integer needs a bigint test (`mrb_integer_p` misses a bignum). A receiver
# with method_missing could answer an unlisted name, so any method_missing class keeps every owner call. With a block,
# the else still only raises, so the block is never called.
#
# The arms are read from the chain the generator emitted, by its brace structure (ArmsCompleteElseScan.chain): the bare
# scopes and `} else {` blocks around the call, each chain's `if` tests in ARM forms on the call's own receiver. It
# stops at any other block, any statement on the path, and any test that may write a variable (the tests before it ran
# on an older value), so an unknown shape only keeps the owner call. BC2CPP_ARMS_COMPLETE_ELSE=0 keeps them all.
module ArmsCompleteElseScan
  # BC2CPP_COLD_ARM (BranchHints.cold_arm) is a label no goto names, kept on the rewritten line.
  SITE = %r{^(?<indent>[ \t]*)(?<cold>BC2CPP_COLD_ARM\ )?(?<dest>r\d+)\ =\ bc2cpp_owner_call_named\(M,
    \ (?<recv>r\d+|self),\ "(?<name>[^"]+)",\ \d,\ BC2CPP_OWNERS\((?<list>[^)]*)\),
    \ (?<blk>mrb_nil_value\(\)|bc2cpp_blk_stack_\d+\.proc\(\)|mrb_obj_value\(\w+\)|\w+),
    \ (?<argc>\d+)(?<args>(?:,\ [\w.]+(?:\(\))?)*)\);\ /\*\ CLOSED_WORLD\ owner-call:\ \S+\ \*/$}x

  CORE_CLASS = { 'array' => 'Array', 'hash' => 'Hash', 'string' => 'String', 'range' => 'Range',
                 'proc' => 'Proc' }.freeze
  R = '(?<r>r\d+|self)'
  CLS = '(?<cls>[\w:]+\((?:M)?\)|M->\w+_class)'
  # [pattern, kind, class]: :any takes a singleton instance, :plain does not, :kind_of takes every descendant, :var
  # compares a class variable a scope declared (CLASS_VAR).
  ARM = [
    [/\Abc2cpp_class_is\(M, #{R}, #{CLS}\)\z/, :any],
    [/\A(?:bc2cpp|mrb)_obj_class\(M, #{R}\) == #{CLS}\z/, :any],
    [/\A#{CLS} == (?:bc2cpp|mrb)_obj_class\(M, #{R}\)\z/, :any],
    [/\A(?<var>bc2cpp_soc|bc2cpp_native_class) == #{CLS}\z/, :var],
    [/\Amrb_(?<t>array|hash|string|range|proc)_p\(#{R}\) && mrb_obj_ptr\(\k<r>\)->c == M->\k<t>_class\z/, :plain],
    [/\Amrb_obj_is_kind_of\(M, #{R}, #{CLS}\)\z/, :kind_of],
    [/\Amrb_symbol_p\(#{R}\)\z/, :any, 'Symbol'],
    [/\Amrb_float_p\(#{R}\)\z/, :any, 'Float'],
    [/\A\(mrb_integer_p\(#{R}\) \|\| mrb_bigint_p\(\k<r>\)\)\z/, :any, 'Integer']
  ].freeze
  CLASS_VAR = /\Astruct\ RClass\*\ (bc2cpp_soc|bc2cpp_native_class)\ =
               \ (mrb_class|bc2cpp_obj_class|mrb_obj_class)\(M,\ (r\d+|self)\);\z/x
  # A test with none of these only reads: a comparison, a call taking values.
  WRITES = /(?<![=!<>])=(?!=)|\+\+|--|(?<!&)&(?!&)/

  module_function

  # `code` (binary) with comments and string/char literal contents blanked, the same length, so brace and header
  # scans see only code.
  def masked(code)
    out = code.dup
    i = 0
    n = code.bytesize
    while i < n
      c = code.getbyte(i)
      if c == 47 && code.getbyte(i + 1) == 47 # //
        j = code.index("\n", i) || n
        out[i, j - i] = ' ' * (j - i)
        i = j
      elsif c == 47 && code.getbyte(i + 1) == 42 # /* */
        j = code.index('*/', i + 2)
        j = j ? j + 2 : n
        out[i, j - i] = code[i, j - i].gsub(/[^\n]/n, ' ')
        i = j
      elsif c == 34 || c == 39 # " '
        j = i + 1
        j += code.getbyte(j) == 92 ? 2 : 1 while j < n && code.getbyte(j) != c && code.getbyte(j) != 10
        j = [j, n].min
        out[i + 1, j - i - 1] = ' ' * (j - i - 1) if j > i + 1
        i = j + 1
      else
        i += 1
      end
    end
    out
  end

  # Brace structure of `masked`: [open => close, close => open, site => the open braces enclosing it].
  def braces(masked, sites)
    open_close = {}
    close_open = {}
    enclosing = {}
    stack = []
    pending = sites.sort
    masked.each_byte.with_index do |c, i|
      enclosing[pending.shift] = stack.dup while pending.first && pending.first <= i
      if c == 123
        stack << i
      elsif c == 125 && (o = stack.pop)
        open_close[o] = i
        close_open[i] = o
      end
    end
    pending.each { |p| enclosing[p] = stack.dup }
    [open_close, close_open, enclosing]
  end

  # [kind, cond, start, before] for the block opened at `open`: :scope (a bare `{`), :else (`} else {`), :if /
  # :else_if with its condition, or :other. `start` is where the header begins, `before` the `}` it follows.
  def header(masked, code, open)
    i = open - 1
    i -= 1 while i >= 0 && ![59, 123, 125].include?(masked.getbyte(i))
    text = masked[i + 1, open - i - 1]
    start = i + 1 + text[/\A\s*/n].bytesize
    body = text.strip
    after_close = i >= 0 && masked.getbyte(i) == 125
    return [:scope, nil, open, nil] if body.empty?
    return [:else, nil, start, i] if body == 'else' && after_close

    m = body.match(/\A(else\s+)?if\s*\((.*)\)\z/mn)
    return [:other, nil, start, nil] unless m && balanced?(m[2]) && (!m[1] || after_close)

    cond_at = start + m.begin(2)
    [m[1] ? :else_if : :if, code[cond_at, m[2].bytesize], start, after_close ? i : nil]
  end

  def balanced?(text)
    depth = 0
    text.each_byte do |ch|
      depth += 1 if ch == 40
      depth -= 1 if ch == 41
      return false if depth.negative?
    end
    depth.zero?
  end

  # The arms on the path to the call at `site` on `recv`, as [kind, class expression or name]. `unknown` collects the
  # tests that are no ARM form on `recv`.
  def chain(code, masked, structure, site, recv, unknown = nil)
    open_close, close_open, enclosing = structure
    arms = []
    vars = Hash.new { |h, k| h[k] = [] }
    child = site
    enclosing.fetch(site).reverse_each do |open|
      kind, _cond, start, before = header(masked, code, open)
      inner = masked[open + 1, child - open - 1].strip
      case kind
      when :scope
        if (decl = inner.match(CLASS_VAR))
          var, reader, reg = decl.captures
          vars.delete(var).to_a.each { |cls| arms << [reader == 'mrb_class' ? :plain : :any, cls] } if reg == recv
          vars.delete(var)
        elsif !inner.empty?
          break
        end
        child = start
      when :else
        break unless inner.empty?

        tests, first = chain_tests(masked, code, open_close, close_open, before)
        break unless first

        stop = false
        tests.each do |cond|
          a = arm(cond, recv)
          unknown << cond if unknown && !a
          if a.nil?
            stop = cond.match?(WRITES)
            break if stop
          elsif a[0] == :var
            vars[a[2]] << a[1]
          else
            arms << a.first(2)
          end
        end
        break if stop

        child = first
      else
        break
      end
    end
    arms
  end

  # The tests of the if / else-if chain whose last arm closes at `close`, last first, and where its `if` begins.
  def chain_tests(masked, code, open_close, close_open, close)
    tests = []
    loop do
      sib = close_open[close]
      return [tests, nil] unless sib && open_close[sib] == close

      k, cond, s, b = header(masked, code, sib)
      return [tests, nil] unless %i[if else_if].include?(k)

      tests << cond
      return [tests, s] if k == :if

      close = b
    end
  end

  # [kind, class, var] for one arm test on `recv`, or nil.
  def arm(cond, recv)
    text = cond.strip
    while (m = text.match(/\Amrb_(?:un)?likely\((.*)\)\z/mn)) && balanced?(m[1])
      text = m[1]
    end
    ARM.each do |pattern, kind, klass|
      m = text.match(pattern)
      next unless m

      names = m.names
      return nil if names.include?('r') && m[:r] != recv

      cls = klass || (names.include?('t') ? CORE_CLASS.fetch(m[:t]) : m[:cls])
      return [kind, cls, names.include?('var') ? m[:var] : nil]
    end
    nil
  end

  # `code` with each owner call the block accepts (given its owners, the arms in front of it and its match) rewritten
  # to the proven nomethod.
  def rewrite(code)
    return code unless code.include?('CLOSED_WORLD owner-call')

    bin = code.b
    sites = []
    # mruby-onig reuses its MatchData region as scan advances, including the
    # final failed search. Retain each site's offsets before that mutation.
    bin.to_enum(:scan, SITE).each { sites << Regexp.last_match.dup }
    sites.select! { |m| m[:args].split(', ').drop(1).size >= m[:argc].to_i }
    return code if sites.empty?

    mask = masked(bin)
    structure = braces(mask, sites.map { |m| m.begin(0) })
    out = +''.b
    pos = 0
    sites.each do |m|
      owners = m[:list].scan(/"([^"]+)"/n).flatten
      arms = chain(bin, mask, structure, m.begin(0), m[:recv])
      next unless yield(owners, arms, m)

      args = m[:args].split(', ').drop(1).first(m[:argc].to_i)
      marker = NomethodReviewed.marker(m[:name], self_receiver: m[:recv] == 'self', site: '?:0')
      out << bin[pos...m.begin(0)]
      out << "#{m[:indent]}// ARMS_COMPLETE_ELSE :#{m[:name]} -- every instance of #{owners.join(', ')} takes an arm " \
             "above\n#{m[:indent]}#{m[:cold]}#{m[:dest]} = bc2cpp_nomethod_named(M, #{m[:recv]}, \"#{m[:name]}\"" \
             "#{args.empty? ? '' : ", #{args.size}, #{args.join(', ')}"}); #{marker}".b
      pos = m.end(0)
    end
    return code if pos.zero?

    (out << bin[pos..]).force_encoding(code.encoding)
  end
end

module ArmsCompleteElse
  def compile_method(label)
    @arms_complete_else_stack ||= []
    outer = !@arms_complete_else_stack.include?(label)
    @arms_complete_else_stack.push(label)
    begin
      result = super
      outer ? arms_complete_else_rewrite(result) : result
    ensure
      @arms_complete_else_stack.pop
    end
  end

  private

  def arms_complete_else_rewrite(result)
    return result unless result.is_a?(Hash) && result[:code].is_a?(String) && !result[:unsupported]
    # A core body runs in the same program: its receivers are the program world's (owner_call_world, but not a
    # resumable variant's).
    world = @closed_world || @core_program_world
    return result if ENV['BC2CPP_ARMS_COMPLETE_ELSE'] == '0' || @clean_probe || !world
    return result if world.global_refusal || !world.method_missing_classes.empty?

    code = ArmsCompleteElseScan.rewrite(result[:code]) { |owners, arms, _m| arms_cover_owners?(world, owners, arms) }
    code.equal?(result[:code]) ? result : result.merge(code: code)
  end

  # See ARMS_COMPLETE_ELSE.
  def arms_cover_owners?(world, owners, arms)
    return false if owners.empty? || arms.empty?

    kinds = Hash.new { |h, k| h[k] = Set.new }
    arms.each do |kind, cls|
      klass = arms_complete_class_name(cls)
      kinds[klass] << kind if klass
    end
    owners.all? { |owner| arms_complete_owner?(world, owner, kinds) }
  end

  ARMS_OPEN_CLASSES = %w[BasicObject Object Module Class].freeze

  def arms_complete_owner?(world, owner, kinds)
    return false if owner.end_with?('.singleton')
    return true if kinds[owner].include?(:kind_of)
    return false if ARMS_OPEN_CLASSES.include?(owner) || world.module_declared?(owner) ||
                    CodeGen.module_names&.include?(owner)

    subclasses = arms_complete_subclasses(world, owner)
    return false unless subclasses

    subclasses.all? do |klass|
      k = kinds[klass]
      !ARMS_OPEN_CLASSES.include?(klass) &&
        (k.include?(:any) || k.include?(:kind_of) || (k.include?(:plain) && world.exact_instances_singleton_free?))
    end
  end

  # `owner` and every class below it: ClosedWorld#known_receiver_subclasses, or `owner` alone when no program, outside
  # or dynamic class subclasses it (#native_subclass_free?) and no native makes a subclass of it (#native_unsubclassed?,
  # NATIVE_LEAF_CORE): the core classes, which the known-subclass bound refuses because their natives spell them.
  def arms_complete_subclasses(world, owner)
    known = world.known_receiver_subclasses(owner)
    return known if known

    [owner] if world.native_subclass_free?([owner]) && world.native_unsubclassed?(owner)
  end

  ARMS_STATE_CLASSES = { 'M->array_class' => 'Array', 'M->hash_class' => 'Hash', 'M->string_class' => 'String',
                         'M->range_class' => 'Range', 'M->proc_class' => 'Proc' }.freeze

  # The class an arm's class expression names: an owner-class getter, an RGSS native class accessor, a class
  # pointer of mrb_state, or the name the arm form itself gives.
  def arms_complete_class_name(cls)
    return ARMS_STATE_CLASSES[cls] if cls.start_with?('M->')
    return cls unless cls.include?('(')

    owner_class_slots[cls] ||
      CodeGen::NATIVE_WRAPPER_CLASS_ACCESSORS.key(cls.delete_prefix('rgss::').delete_suffix('()'))
  end
end

CodeGen.prepend(ArmsCompleteElse)
