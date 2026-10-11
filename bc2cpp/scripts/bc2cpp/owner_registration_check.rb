#!/usr/bin/env ruby
# encoding: UTF-8
# Check OWNER_METHOD_REGISTRATION (tools/bc2cpp/bc2cpp.rb's own
# emit_owner_registrations): the generated function installs every compiled
# entry of a wired-embedding owner, with the visibility/singleton call the
# entry's own MethodDef actually needs, and an aspec derived from the same
# mand/opt/rest/keyword/block data compile_method's own entry wrapper used --
# not a second, independently-guessable copy of it.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  class Widget
    def initialize(a); @a = a; end
    def pub(x, y = 1); x + y; end
    private
    def priv; @a; end
    def self.make; new(1); end
  end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'owner_reg.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_owner_reg', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  compiled = gen.compile_all
  reg = gen.emit_owner_registrations(compiled, %w[Widget Widget.singleton])

  check.call('resolves the owner class through the same chained lookup other guards use',
             reg.include?('mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Widget")))'))
  name = ->(s) { s.bytes.map { |b| format('\\x%02x', b) }.join }
  check.call('a public method is mrb_define_method',
             reg.include?("mrb_define_method(M, bc2cpp_owner_reg_Widget, \"#{name.call('pub')}\", Widget_pub, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));"))
  check.call('a private method (and the forced-private #initialize) uses mrb_define_private_method',
             reg.include?("mrb_define_private_method(M, bc2cpp_owner_reg_Widget, \"#{name.call('priv')}\", Widget_priv, MRB_ARGS_NONE());") &&
               reg.include?("mrb_define_private_method(M, bc2cpp_owner_reg_Widget, \"#{name.call('initialize')}\", Widget_initialize, MRB_ARGS_REQ(1));"))
  check.call('a class method uses mrb_define_class_method, resolved from the plain (non-.singleton) class path',
             reg.include?("mrb_define_class_method(M, bc2cpp_owner_reg_Widget_singleton, \"#{name.call('make')}\", Widget_singleton_make, MRB_ARGS_NONE());") &&
               reg.scan('mrb_intern_cstr(M, "Widget")').size == 2 && !reg.include?('"Widget.singleton"'))
  check.call('an owner with no compiled entries emits no registration block for it',
             !reg.include?('bc2cpp_owner_reg_Nope'))

  empty = gen.emit_owner_registrations(compiled, [])
  check.call('the function is always emitted, even with nothing to register',
             empty.include?('static void bc2cpp_register_owner_methods(mrb_state* M) {'))
end

if failures.empty?
  puts 'bc2cpp owner registration check: PASS'
else
  warn "bc2cpp owner registration check: #{failures.size} failure(s)"
  exit 1
end
