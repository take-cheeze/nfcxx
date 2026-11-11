# frozen_string_literal: true

# NativeReturnKinds: the Ruby kind a C method body returns, read from its return statements. A body whose every return
# builds a value of one known kind gets that kind as its RBS return type, and one whose returns are that kind or nil gets
# the optional type (`String?`); anything else (another mix, a return of a value the table does not name, a body with no
# return) stays untyped. Only the expression's own call counts: `mrb_assoc_new(M, mrb_float_value(x), ...)` is an
# Array, not the Float its first argument builds.
#
# The table names the mruby C API calls whose result kind is fixed by the call itself (`mrb_str_new` is a String,
# `mrb_fixnum_value` an Integer). A returned local is followed through its assignments in the same body, so
# `mrb_value ret = mrb_nil_value(); ... return ret;` is nil. `self` is kept apart: it is the receiver's class.
module NativeReturnKinds
  Entry = Struct.new(:pattern, :kind)

  ENTRIES = [
    Entry.new(/\bmrb_nil_value\s*\(/, 'nil'),
    Entry.new(/\bmrb_(?:true_value|false_value|bool_value)\s*\(/, 'bool'),
    Entry.new(/\bmrb_(?:fixnum_value|int_value)\s*\(/, 'Integer'),
    # Bignum constructors (MRB_USE_BIGINT): a bignum is an Integer instance.
    # Bignum operations that return a value: each result is an Integer (a bignum or a fixnum). to_s (a String) and
    # divmod (an Array) are left out, and so are the helpers that return C scalars.
    Entry.new(/\bmrb_bint_(?:new_\w+|sqrt|add|sub|mul|div|mod|rem|pow|gcd|lcm|neg|abs|and|or|xor|lshift|rshift|copy|add_n|sub_n|mul_n|add_ii|sub_ii|mul_ii|rev|reduce|powm)\s*\(/, 'Integer'),
    Entry.new(/\bmrb_float_value\s*\(/, 'Float'),
    Entry.new(/\bmrb_(?:str_new|str_new_cstr|str_new_static|str_buf_new|str_dup|str_cat|str_substr|str_resize|str_plus|format)\w*\s*\(/,
              'String'),
    # mrb_bint_to_s builds its digits with mrb_str_new (mruby-bigint: every return is a String).
    Entry.new(/\bmrb_bint_to_s\s*\(/, 'String'),
    # mrb_obj_as_string returns the object's to_s converted to a String (rb_any_to_s when to_s is not one).
    Entry.new(/\bmrb_(?:sym_str|obj_as_string)\s*\(/, 'String'),
    Entry.new(/\bmrb_(?:ary_new|ary_new_capa|ary_new_from_values|ary_dup)\s*\(/, 'Array'),
    # mrb_assoc_new builds a two-element Array (array.c).
    Entry.new(/\bmrb_assoc_new\s*\(/, 'Array'),
    Entry.new(/\bmrb_(?:hash_new|hash_new_capa|hash_dup)\s*\(/, 'Hash'),
    Entry.new(/\bmrb_symbol_value\s*\(/, 'Symbol')
  ].freeze

  SELF = 'self'
  NIL = 'nil'
  RETURN = /\breturn\s+([^;]+);/.freeze
  IDENT = /\A\w+\z/.freeze
  CALL_HEAD = /\A(\w+)\s*\(/.freeze

  module_function

  # The kind a call to the function +name+ builds, or nil when the table does not name it.
  def kind_of_call(name)
    ENTRIES.find { |entry| "#{name}(".match?(entry.pattern) }&.kind
  end

  # The kind of an expression that is a constructor call, by its outermost callee.
  def kind_of_constructor(expr)
    name = expr.strip[CALL_HEAD, 1]
    name && kind_of_call(name)
  end

  # The kind one return expression yields, or nil when the table does not name it.
  def kind_of_expr(expr, body)
    text = expr.strip
    return SELF if text == 'self'
    return kind_of_local(text, body) if text.match?(IDENT)

    kind_of_constructor(text)
  end

  # The kind of a local whose every assignment in the body yields one kind (or that kind and nil); nil when any
  # assignment is unknown.
  def kind_of_local(name, body)
    assigns = body.scan(/\b#{Regexp.escape(name)}\s*=\s*([^;]+);/).flatten
    return nil if assigns.empty?

    join_optional(assigns.map { |expr| kind_of_constructor(expr) })
  end

  # The kind every return of +body+ yields (or that kind and nil), or nil.
  def kind_of_body(body)
    exprs = body.scan(RETURN).flatten
    return nil if exprs.empty?

    join_optional(exprs.map { |expr| kind_of_expr(expr, body) })
  end

  # The one kind of +kinds+, or `K?` when they are K and nil (an optional kind counts as both); nil for any other mix
  # or when one is unknown (nil).
  def join_optional(kinds)
    return nil if kinds.empty? || kinds.any?(&:nil?)

    parts = kinds.flat_map { |k| k.end_with?('?') ? [k.chomp('?'), NIL] : [k] }.uniq
    return parts.first if parts.size == 1
    return nil unless parts.size == 2 && parts.include?(NIL)

    "#{(parts - [NIL]).first}?"
  end

  # The RBS return type of a kind for a method of +owner+ (a class name). `self` is the receiver: an instance method
  # returns `self`, and a class method returns the class object, which RBS spells `singleton(owner)`.
  def rbs_of(kind, owner:, singleton:)
    return 'untyped' if kind.nil?

    base = kind.chomp('?')
    base = singleton ? "singleton(#{owner})" : 'self' if base == SELF
    kind.end_with?('?') ? "#{base}?" : base
  end
end
