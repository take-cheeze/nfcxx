#!/usr/bin/env ruby
# encoding: UTF-8
# Check UNIQUE_CLASS_NAME (tools/bc2cpp/unique_class_names.rb): a bare class
# name recorded by trace_new_target is canonicalized to "P::N" only when N has
# exactly one definition in the whole program and P::N is reachable from the
# site. Every refused shape below would let a lookup reach a different class.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/unique_class_names_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Lib
    class Thing; end
    class Thing; def again; end; end
    class Dup; end
    class Reassigned; end
    class NativeTop; end
    class NativeOther; end
    class Forwarded; end
    class ForeignDup; end
  end
  module Hidden
    class Secret; end
    class User
      def initialize; @secret = Secret.new; end
    end
  end
  module Other
    Reassigned = 1
  end
  module Hidden
    class Lib::Compact; end
  end
  class Object
    include Lib
  end
  class App
    class Dup; end
    def initialize
      @thing = Thing.new
      @dup = Dup.new
      @secret = Secret.new
      @forwarded = Forwarded.new
    end
  end
RUBY

NATIVE = <<~'CXX'
  static void define_forwarded(mrb_state* M, RClass* m) {
    mrb_define_class_under(M, m, "Forwarded", M->object_class);
  }

  void gem_init(mrb_state* M) {
    RClass* m = mrb_define_module(M, "Lib");
    mrb_define_class_under(M, m, "Thing", M->object_class);
    define_forwarded(M, m);
    mrb_define_class(M, "NativeTop", M->object_class);
    RClass* other = mrb_class_get(M, "Somewhere");
    mrb_define_class_under(M, other, "NativeOther", M->object_class);
  }
CXX

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'unique_class_names.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_unique_class_names', dir)
  order = dfs_order(ireps, root_label)
  registry, _superclass_of, _containers, included_modules = build_registry(ireps, root_label)

  native = File.join(dir, 'native.cxx')
  File.write(native, NATIVE)
  foreign = File.join(dir, 'foreign.rb')
  File.write(foreign, "module Elsewhere\n  class ForeignDup; end\nend\n")
  mutating = File.join(dir, 'mutating.rb')
  File.write(mutating, "Lib.const_set(:Thing, Class.new)\n")
  hook_source = "class Module\n  def const_missing(name); Object; end\nend\n"
  hook = File.join(dir, 'hook.rb')
  File.write(hook, "module Lib\n  class Thing; end\nend\n#{hook_source}")
  hook_ireps, hook_root = compile_ireps(hook, 'bc2cpp_unique_hook', dir)
  missing = File.join(dir, 'missing.rb')
  File.write(missing, hook_source)

  table = UniqueClassNames.analyze(ireps, root_label, [native], [foreign])
  check.call('a class reopened in one scope and defined natively under it is canonical', table['Thing'], 'Lib::Thing')
  check.call('a native definition through a forwarded RClass* parameter agrees', table['Forwarded'], 'Lib::Forwarded')
  check.call('a name defined in two scopes stays unresolved', table['Dup'], nil)
  check.call('a name also assigned with SETCONST stays unresolved', table['Reassigned'], nil)
  check.call('a compact `class Lib::Compact` stays unresolved', table['Compact'], nil)
  check.call('a native top-level definition stays unresolved', table['NativeTop'], nil)
  check.call('a native definition under an unknown module stays unresolved', table['NativeOther'], nil)
  check.call('a foreign definition stays unresolved', table['ForeignDup'], nil)
  check.call('no NATIVE_SRCS proves nothing', UniqueClassNames.analyze(ireps, root_label, nil, [foreign]), {})
  check.call('const_set anywhere proves nothing', UniqueClassNames.analyze(ireps, root_label, [native], [mutating]), {})
  check.call('a closed-world const_missing definition proves nothing',
             UniqueClassNames.analyze(hook_ireps, hook_root, [native], [foreign]), {})
  check.call('a foreign const_missing definition proves nothing',
             UniqueClassNames.analyze(ireps, root_label, [native], [missing]), {})

  UniqueClassNames.table = table
  UniqueClassNames.object_mixins = Array(included_modules['Object'])
  check.call('a module included into Object is reachable from any owner',
             UniqueClassNames.resolve('Thing', 'App'), 'Lib::Thing')
  UniqueClassNames.object_mixins = ['RGSS']
  check.call('native constructors recognize normalized Object-included RGSS', object_includes_rgss?, true)
  UniqueClassNames.object_mixins = ['Object::RGSS']
  check.call('native constructors recognize qualified Object-included RGSS', object_includes_rgss?, true)
  UniqueClassNames.object_mixins = Array(included_modules['Object'])
  check.call('a module neither enclosing nor included is not reachable', UniqueClassNames.resolve('Secret', 'App'), nil)
  check.call('an enclosing module is reachable lexically', UniqueClassNames.resolve('Secret', 'Hidden::User'),
             'Hidden::Secret')
  check.call('a name prefix is not a lexical scope', UniqueClassNames.resolve('Secret', 'HiddenX::User'), nil)

  layout = ClassLayout.known(ClassLayout.analyze(ireps, registry))
  check.call('ClassLayout records the canonical class', layout['App']&.[]('thing'), 'Lib::Thing')
  check.call('ClassLayout keeps an ambiguous name as written', layout['App']&.[]('dup'), 'Dup')
  check.call('ClassLayout keeps an unreachable name as written', layout['App']&.[]('secret'), 'Secret')
  check.call('ClassLayout resolves a lexically enclosed name', layout['Hidden::User']&.[]('secret'), 'Hidden::Secret')

  init = registry['initialize'].find { |d| d.owner == 'App' }
  irep = ireps.fetch(init.irep)
  setiv = irep.instructions.index { |i| i.op == 'SETIV' && i.args.include?('@thing') }
  reg = irep.instructions[setiv].regs.first
  check.call('construct-target callers still get the written name',
             trace_new_target(irep, setiv, reg, nil, 0, nil, owner: 'App', canonical: false), 'Thing')

  UniqueClassNames.table = nil
  check.call('no table leaves every name as written', UniqueClassNames.resolve('Thing', 'App'), nil)
end

if failures.empty?
  puts 'bc2cpp unique class names check: PASS'
else
  warn "bc2cpp unique class names check: #{failures.size} failure(s)"
  exit 1
end
