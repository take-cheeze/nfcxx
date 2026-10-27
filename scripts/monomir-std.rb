# Summaries of the standard library functions that small Rust programs call, for
# scripts/monomir-to-pathb.rb --borrow (docs/notes/mrustc-borrowck.md, "Standard library calls").
#
# The checker refuses a call without a (call-effects ...) summary. The functions below are not
# checked; their summaries are trusted, as for scripts/pathb-libc.effects, and each says only what
# the borrow checker needs: which arguments are read or written through, and where a returned
# reference points. A function that matches no entry keeps no summary, and its caller is refused.
#
# Entries match mrustc's monomorphised path, normalized by MonomirStd.normalize (crate versions,
# lifetimes and the dump's /*S*/ markers removed), so that `T` is the instance's element type:
#   <alloc::vec::Vec<i32,alloc::alloc::Global>>::push
#   <alloc::vec::Vec<i32,alloc::alloc::Global> as core::ops::index::Index<usize>>::index
# Non-generic functions have no body in the dump, and so no path; they match by symbol.
#
# Containers are covered only for an element type that is a primitive scalar. Such an element holds
# no reference, so a Vec or Box of it never keeps a borrow, and its drop reads nothing but its own
# place. Pushing a reference into a Vec would keep it, which a summary cannot say.
module MonomirStd
  SCALARS = %w[u8 i8 u16 i16 u32 i32 u64 i64 usize isize f32 f64 bool char].freeze
  VEC = 'alloc::vec::Vec<(?<t>\w+),alloc::alloc::Global>'
  BOX = 'alloc::boxed::Box<(?<t>\w+),alloc::alloc::Global>'
  RANGE = 'core::ops::range::Range<(?<t>\w+)>'
  OPTION = 'core::option::Option<(?<t>\w+)>'

  # Each entry: [path pattern, argument effects, result]. An argument effect is :read or :write for
  # a reference argument (its referent), :value for a scalar, :byval for a struct passed by value
  # (read, and not kept). The `T` the pattern names must be a scalar. The result is :void, :scalar,
  # :init (an aggregate the callee initializes in the caller's buffer, which comes first), or
  # [:alias, ARG, :shared|:exclusive], a reference into argument ARG's referent.
  #
  # Vec's element storage is on the heap, which the checker does not track. A reference to an
  # element is modelled as one into the Vec itself, at offset 0, with the Vec's loan: that is the
  # loan rustc gives it too, and it conflicts with every later use of the Vec through `&mut`.
  SUMMARIES = [
    [/\A<#{VEC}>::new\z/, [], :init],
    [/\A<#{VEC}>::with_capacity\z/, [:value], :init],
    [/\A<#{VEC}>::push\z/, [:write, :value], :void],
    [/\A<#{VEC}>::clear\z/, [:write], :void],
    [/\A<#{VEC}>::truncate\z/, [:write, :value], :void],
    [/\A<#{VEC}>::pop\z/, [:write], :init],
    [/\A<#{VEC}>::len\z/, [:read], :scalar],
    [/\A<#{VEC}>::is_empty\z/, [:read], :scalar],
    [/\A<#{VEC}>::capacity\z/, [:read], :scalar],
    [/\A<#{VEC} as core::ops::index::Index<usize>>::index\z/, [:read, :value], [:alias, 0, :shared]],
    [/\A<#{VEC} as core::ops::index::IndexMut<usize>>::index_mut\z/, [:write, :value], [:alias, 0, :exclusive]],
    # Drop glue frees the Vec's buffer: an exclusive use of the Vec's own bytes, which conflicts
    # with any loan of it still live (a reference that outlives the Vec).
    [/\A<#{VEC}>::#drop_glue\z/, [:write], :void],
    # A Box of a scalar is modelled as holding its value in its own place (box_scalar), so
    # `&*b` is a loan of `b`, as in rustc, and dropping or moving `b` conflicts with it.
    [/\A<#{BOX}>::new\z/, [:value], :init],
    [/\A<#{BOX}>::#drop_glue\z/, [:write], :void],
    # `for i in a..b`: the Range is a struct of two scalars, and next returns an Option of one.
    [/\A<#{RANGE} as core::iter::traits::collect::IntoIterator>::into_iter\z/, [:byval], :init],
    [/\A<#{RANGE} as core::iter::traits::iterator::Iterator>::next\z/, [:write], :init],
    [/\A<#{OPTION}>::unwrap\z/, [:byval], :scalar],
    [/\A<#{OPTION}>::is_some\z/, [:read], :scalar],
    [/\A<#{OPTION}>::is_none\z/, [:read], :scalar]
  ].freeze

  # Option<T> of a scalar is an enum, which gets no layout from its type record. It holds no
  # pointer, so its bytes are described as one array: a call that initializes it defines them all.
  OPTION_TYPE = /\AZRG2cE9core0_0_06option6Option1g/

  def self.layout(name, types)
    t = types[name]
    return nil unless name.match?(OPTION_TYPE) && t && t[:tag] && t[:size] > 0 && t[:size] % t[:align] == 0
    plain = ->(ty) { ty == '()' || SCALARS.include?(ty) }
    ok = t[:fields].all? do |f|
      ty = f[:type].strip
      plain.call(ty) || (types[ty] && types[ty][:fields].all? { |g| plain.call(g[:type].strip) })
    end
    return nil unless ok
    "(borrow-layout (struct #{name.inspect}) #{t[:size]} #{t[:align]} (field \"bytes\" 0 (array #{t[:size]} unsigned_char)))"
  end

  BOX_TYPE = /\AZRG2cF10alloc0_0_05boxed3Box2g.*G2c_A5alloc6Global0g\z/

  # The scalar type T when TY is a Box<T> of one, else nil: the Box's first fields lead through
  # Unique and NonNull to its `*const T`.
  def self.box_scalar(ty, types)
    return nil unless ty && ty.strip.match?(BOX_TYPE)
    t = ty.strip
    4.times do
      f = types[t] && types[t][:fields][0]
      return nil unless f
      t = f[:type].strip
      if t =~ /\A\*(const|mut) (\w+)\z/
        return SCALARS.include?($2) ? $2 : nil
      end
    end
    nil
  end

  # println! and print! end in std::io::_print (eprintln! in _eprint), which takes the
  # fmt::Arguments by value and reads it, and through it the formatted values. It keeps nothing.
  # A panic aborts (mrustc links panic_abort), so no summary here may throw.
  SYMBOLS = {
    'ZRG3cD8std0_0_02io5stdio7__print0g' => :print,
    'ZRG3cD8std0_0_02io5stdio8__eprint0g' => :print
  }.freeze

  ARGUMENT = 'ZRG3cE9core0_0_03fmt2rt8Argument0g'
  ARGUMENTS = 'ZRG2cE9core0_0_03fmt9Arguments0g'

  # fmt::rt::Argument and fmt::Arguments hold the references they format, so their constructors are
  # not summaries (a summary keeps no pointer) but stores: the call becomes the stores of the
  # references into the value, as the constructor's body does. The checker then tracks the borrows
  # in the value like any other stored reference, so `let a = format_args!("{}", x); x = 2; ...a`
  # is a conflict (E0506). Both types are enums inside, which get no layout of their own; these are
  # the layouts of the variant the constructors build.
  LAYOUTS = {
    ARGUMENT => "(borrow-layout (struct #{ARGUMENT.inspect}) 24 8 (field \"tag\" 0 unsigned_long) " \
                "(field \"value\" 8 (ptr void)) (field \"formatter\" 16 (ptr void)))",
    ARGUMENTS => "(borrow-layout (struct #{ARGUMENTS.inspect}) 48 8 (field \"pieces\" 0 (ptr void)) " \
                 "(field \"pieces_len\" 8 unsigned_long) (field \"fmt\" 16 (ptr void)) " \
                 "(field \"fmt_len\" 24 unsigned_long) (field \"args\" 32 (ptr void)) " \
                 "(field \"args_len\" 40 unsigned_long))"
  }.freeze

  INLINE = [
    [/\A<core::fmt::rt::Argument>::new_(display|debug|lower_hex|upper_hex|octal|binary|lower_exp|upper_exp)<.*>\z/, :argument],
    [/\A<core::fmt::Arguments>::new_v1<.*>\z/, :arguments],
    [/\A<core::fmt::Arguments>::new_const<.*>\z/, :arguments_const]
  ].freeze

  # mrustc ends the storage of format_args!'s array of Arguments with the match that builds it,
  # before the fmt::Arguments that points to it is used (rustc keeps it to the end of the statement,
  # or of the block for `let a = format_args!(...)`). The array is the compiler's own temporary, which
  # nothing else can borrow, so its storage is kept to the end of the function instead. Ending it
  # would cut the chain from the Arguments to the references the array holds.
  def self.keeps_storage?(ty)
    !ty.nil? && ty.match?(/\A\[#{ARGUMENT}; \d+\]\z/)
  end

  # "<::"alloc-0_0_0"::vec::Vec<i32,::"alloc-0_0_0"::alloc::Global/*S*/,>/*S*/ /*- <i32,>*/>::push<'#local0,>"
  # becomes "<alloc::vec::Vec<i32,alloc::alloc::Global>>::push".
  def self.normalize(path)
    s = path.gsub(%r{/\*[SEU]\*/}, '')
    s = s.gsub(%r{/\*- .*?\*/}, '')
    s = s.gsub(/'[#\w]+,?/, '')
    s = s.gsub(/::"([A-Za-z_]+)-[0-9_]+"/, '::\1')
    s = s.gsub(/(\A|[<,( ])::/, '\1')
    s = s.gsub(/\s+/, ' ').gsub(/ >/, '>')
    s = s.gsub(/<>/, '').gsub(/,>/, '>')
    s.strip
  end

  # path: name => normalized path, from the dump's "/* PATH */" line before each fn.
  # sig: name => [param types, return type].
  def self.scan(src)
    @paths = {}
    @sigs = {}
    src.scan(%r{^/\* (.*) \*/\nfn (\S+?)\((.*)\): (.+?)(?: \{| = [^\n]*;)$}) do |path, name, params, ret|
      @paths[pb_sym(name)] = normalize(path)
      @sigs[pb_sym(name)] = [parse_params_str(params), ret.strip]
    end
  end

  # The lowering of a call to a constructor that keeps references, or nil.
  def self.inline(name)
    path = @paths && @paths[name]
    return nil unless path
    INLINE.each { |re, kind| return kind if re.match?(path) }
    nil
  end

  # Statements for an inline constructor's call: DEST is the address of the result, ARGS the
  # argument values. Returns [statements, next register].
  def self.lower(kind, dest, args, regi)
    out = []
    field = lambda do |off, ty, val|
      if off == 0
        out << "(store #{ty} #{dest} #{val})"
      else
        out << "(let %#{regi} (ptr #{ty}) (offset #{dest} #{off}))"
        out << "(store #{ty} %#{regi} #{val})"
        regi += 1
      end
    end
    case kind
    when :argument
      field.call(0, 'unsigned_long', '(const unsigned_long 0)')
      field.call(8, '(ptr void)', args[0])
      field.call(16, '(ptr void)', '(null (ptr void))')
    when :arguments, :arguments_const
      field.call(0, '(ptr void)', args[0])
      field.call(8, 'unsigned_long', '(const unsigned_long 0)')
      field.call(16, '(ptr void)', '(null (ptr void))')
      field.call(24, 'unsigned_long', '(const unsigned_long 0)')
      field.call(32, '(ptr void)', kind == :arguments ? args[1] : '(null (ptr void))')
      field.call(40, 'unsigned_long', '(const unsigned_long 0)')
    end
    [out, regi]
  end

  # The (call-effects ...) form for NAME, or nil when no entry describes it.
  def self.summary(name, types)
    if SYMBOLS[name] == :print
      return "(call-effects #{name.inspect} (returns void) (nothrow) (noescape) (closed) " \
             "(args (byval-deep (struct #{ARGUMENTS.inspect}))))"
    end
    path = @paths && @paths[name]
    return nil unless path
    SUMMARIES.each do |re, effects, result|
      m = re.match(path)
      next unless m
      return nil unless SCALARS.include?(m[:t])
      params, ret = @sigs[name]
      return nil unless params.length == effects.length
      args = []
      args << "(init #{rust_type_to_pathb(ret, types)})" if result == :init
      params.each_with_index do |t, i|
        t = t.strip
        case effects[i]
        when :read, :write
          return nil unless t =~ /\A&(mut |move )?(.+)\z/
          pointee = rust_type_to_pathb($2, types)
          return nil unless pointee.start_with?('(struct ') && !pointee.start_with?('(struct "&')
          args << "(#{effects[i]} #{pointee})"
        when :value
          return nil unless SCALARS.include?(t)
          args << "(value #{rust_type_to_pathb(t, types)})"
        when :byval
          pt = rust_type_to_pathb(t, types)
          return nil unless pt.start_with?('(struct ') && !pt.start_with?('(struct "&')
          args << "(byval #{pt})"
        end
      end
      returns =
        case result
        when :void, :init then 'void'
        when :scalar
          return nil unless SCALARS.include?(ret)
          rust_type_to_pathb(ret, types)
        else
          return nil unless ret =~ /\A&(mut )?(\w+)\z/ && SCALARS.include?($2)
          "#{rust_type_to_pathb(ret, types)} (from-arg #{result[1]} 0 #{result[2]})"
        end
      return "(call-effects #{name.inspect} (returns #{returns}) (nothrow) (noescape) (closed) (args #{args.join(' ')}))"
    end
    nil
  end
end
