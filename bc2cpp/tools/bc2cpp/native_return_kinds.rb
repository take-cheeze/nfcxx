# frozen_string_literal: true

# NativeReturnKinds: the Ruby kind a C method body returns, read from its return statements. A body whose every return
# builds a value of one known kind gets that kind as its RBS return type; anything else (a mix, a return of a value
# the table does not name, a body with no return) stays untyped.
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
    # mrb_obj_as_string returns the object's to_s converted to a String (rb_any_to_s when to_s is not one).
    Entry.new(/\bmrb_(?:sym_str|obj_as_string)\s*\(/, 'String'),
    Entry.new(/\bmrb_(?:ary_new|ary_new_capa|ary_new_from_values|ary_dup)\s*\(/, 'Array'),
    Entry.new(/\bmrb_(?:hash_new|hash_new_capa|hash_dup)\s*\(/, 'Hash'),
    Entry.new(/\bmrb_symbol_value\s*\(/, 'Symbol')
  ].freeze

  SELF = 'self'
  RETURN = /\breturn\s+([^;]+);/.freeze
  IDENT = /\A\w+\z/.freeze

  module_function

  # The kind one return expression yields, or nil when the table does not name it.
  def kind_of_expr(expr, body)
    text = expr.strip
    return SELF if text == 'self'
    return kind_of_local(text, body) if text.match?(IDENT)

    ENTRIES.find { |entry| text.match?(entry.pattern) }&.kind
  end

  # The kind of a local whose every assignment in the body yields one kind; nil when any assignment is unknown.
  def kind_of_local(name, body)
    assigns = body.scan(/\b#{Regexp.escape(name)}\s*=\s*([^;]+);/).flatten
    return nil if assigns.empty?

    kinds = assigns.map { |expr| ENTRIES.find { |entry| expr.strip.match?(entry.pattern) }&.kind }
    kinds.uniq.size == 1 ? kinds.first : nil
  end

  # The one kind every return of +body+ yields, or nil.
  def kind_of_body(body)
    exprs = body.scan(RETURN).flatten
    return nil if exprs.empty?

    kinds = exprs.map { |expr| kind_of_expr(expr, body) }
    return nil if kinds.any?(&:nil?)

    kinds.uniq.size == 1 ? kinds.first : nil
  end

  # The RBS return type of a kind for a method of +owner+ (a class name). `self` is the receiver: an instance method
  # returns `self`, and a class method returns the class object, which RBS spells `singleton(owner)`.
  def rbs_of(kind, owner:, singleton:)
    return 'untyped' if kind.nil?
    return(singleton ? "singleton(#{owner})" : 'self') if kind == SELF

    kind
  end
end
