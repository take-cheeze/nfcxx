# frozen_string_literal: true

require_relative '../../tools/bc2cpp/native_return_kinds'

module NativeReturnKindsCases
  def self.ret(body)
    NativeReturnKinds.rbs_of(NativeReturnKinds.kind_of_body(body), owner: 'Foo', singleton: false)
  end

  def self.run(check)

    puts '== kinds of direct returns'
    check.call('a fixnum return is Integer', ret('{ return mrb_fixnum_value(x); }') == 'Integer')
    check.call('a str_new return is String', ret('{ return mrb_str_new_cstr(M, s); }') == 'String')
    check.call('a bignum constructor return is Integer', ret('{ return mrb_bint_new_uint64(M, v); }') == 'Integer')
    check.call('a bignum sqrt return is Integer', ret('{ return mrb_bint_sqrt(M, v); }') == 'Integer')
    check.call('a bignum to_s return is not classed', ret('{ return mrb_bint_to_s(M, v, 10); }') != 'Integer')
    check.call('a sym_str return is String', ret('{ return mrb_sym_str(M, sym); }') == 'String')
    check.call('an obj_as_string return is String', ret('{ return mrb_obj_as_string(M, obj); }') == 'String')
    check.call('a mrb_format return is String', ret('{ return mrb_format(M, "%d", x); }') == 'String')
    check.call('a nil return is nil', ret('{ return mrb_nil_value(); }') == 'nil')
    check.call('a bool return is bool', ret('{ return mrb_bool_value(a != 0); }') == 'bool')
    check.call('a self return is self on an instance method', ret('{ return self; }') == 'self')
    check.call('a self return on a class method is the class object', NativeReturnKinds.rbs_of(
      NativeReturnKinds.kind_of_body('{ return self; }'), owner: 'Foo', singleton: true
    ) == 'singleton(Foo)')

    puts '== mixed and unknown returns'
    check.call('a body returning nil and an Integer is untyped',
               ret('{ if (a) return mrb_nil_value(); return mrb_fixnum_value(1); }') == 'untyped')
    check.call('a body returning a call the table does not name is untyped',
               ret('{ return other_fn(M, self); }') == 'untyped')
    check.call('a body with no return is untyped', ret('{ mrb_nil_value(); }') == 'untyped')

    puts '== returned locals'
    check.call('a local assigned one kind is that kind',
               ret('{ mrb_value r = mrb_nil_value(); if (a) { return r; } return r; }') == 'nil')
    check.call('a local assigned two kinds is untyped',
               ret('{ mrb_value r = mrb_nil_value(); r = mrb_fixnum_value(1); return r; }') == 'untyped')
    check.call('a local assigned an unknown value is untyped',
               ret('{ mrb_value r = helper(M); return r; }') == 'untyped')
  end
end
