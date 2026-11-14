#!/usr/bin/env ruby
# frozen_string_literal: true

# NAME_SINKS (tools/bc2cpp/static_dispatch_name_sinks.rb): while every native that turns a String into a method name is
# an audited one, an identifier-shaped string literal and the fragments of a built name look nothing up.
#
#   - the inventory reads a conversion call (a `mrb_obj_to_sym` and its macros, a raw `mrb_intern` over a String's bytes)
#     and an `n` argument format in the function holding it, and nothing else: not a comment, the converter's own
#     definition, or an `mrb_intern_cstr` of a literal;
#   - the audit holds when the natives hold only listed functions, and says which function it does not know;
#   - the closed build's own natives hold only listed ones (a world without 3rd/mruby is skipped);
#   - a String literal given to `send` names its method (SYMBOL_USES), one that is compared, stored or built does not,
#     and a computed name refuses the proof.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/name_sinks_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'set'
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_name_sinks'
require_relative '../../tools/bc2cpp/static_dispatch_symbol_uses'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('name_sinks_check')
suite.require_mrbc!
sinks = StaticDispatchNameSinks

Dir.mktmpdir('name_sinks') do |root|
  write = lambda do |rel, text|
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end
  vm = write.call('3rd/mruby/src/vm.c', <<~C)
    #define to_sym(mrb, ss) mrb_obj_to_sym(mrb, ss)
    // mrb_obj_to_sym(mrb, commented)
    static mrb_value
    send_method(mrb_state *mrb, mrb_value self, mrb_bool pub)
    {
      mrb_get_args(mrb, "n*&", &name, &argv, &argc, &block);
      name = mrb_obj_to_sym(mrb, regs[0]);
      other = to_sym(mrb, x);
      sym = mrb_intern_cstr(mrb, "literal");
      return mrb_nil_value();
    }

    mrb_sym
    mrb_obj_to_sym(mrb_state *mrb, mrb_value name)
    {
      return 0;
    }
  C
  inv = sinks.inventory([vm], root)
  suite.check('a conversion call and an `n` format are found in their function',
              inv.include?('src/vm.c:send_method:to_sym') && inv.include?('src/vm.c:send_method:name_arg'))
  suite.check('a macro of a converter counts, the converter\'s own definition and a comment do not',
              inv == ['src/vm.c:send_method:name_arg', 'src/vm.c:send_method:to_sym'])
  raw = write.call('mruby-x/src/raw.c', <<~C)
    static mrb_value
    f(mrb_state *mrb, mrb_value s)
    {
      mrb_sym a = mrb_intern(mrb, RSTRING_PTR(s), RSTRING_LEN(s));
      mrb_sym b = mrb_intern_static(mrb, "name", 4);
      return mrb_nil_value();
    }
  C
  suite.check('mrb_intern over a String\'s bytes is a conversion, over a literal it is not',
              sinks.inventory([raw], root) == ['mruby-x/src/raw.c:f:to_sym'])
  suite.check('the audit holds for listed functions only', sinks.audited?([vm], root) && !sinks.audited?([vm, raw], root))
  suite.check('an unlisted function is named by the difference',
              sinks.differences([vm, raw], root).first == ['mruby-x/src/raw.c:f:to_sym'])
end

root = BC2CPP_WORLD_ROOT
if File.directory?(File.join(root, '3rd/mruby/src'))
  _ruby, native = StaticDispatchRegistrations.outside_world_files(root, closed_only: true)
  unknown, = sinks.differences(native, root)
  suite.check("the closed build's natives hold only audited conversions (#{unknown.first(3).join(', ')})", unknown.empty?)
else
  puts '  skip the world natives: no 3rd/mruby'
end

lookups = lambda do |source|
  names = Set.new
  result = nil
  suite.compile(source) { |ireps, _root, _dir| result = StaticDispatchSymbolUses.lookups(ireps, arg_names: names) }
  [result, names]
end

named, = lookups.call(<<~RUBY)
  class A
    def go(o, h)
      o.send("by_string")
      o.send(:by_symbol)
      h["compared"] = "stored"
      h["compared"] == "stored"
    end
  end
RUBY
suite.check('a String literal argument of send names its method', named&.include?('by_string'))
suite.check('a Symbol literal argument of send names its method', named&.include?('by_symbol'))
suite.check('a compared or stored String literal names nothing', named && !named.include?('compared') && !named.include?('stored'))
refused, = lookups.call(<<~RUBY)
  class A
    def go(o, name)
      o.send(name + "_x")
    end
  end
RUBY
suite.check('a computed name refuses the proof', refused.nil?)

suite.finish!
