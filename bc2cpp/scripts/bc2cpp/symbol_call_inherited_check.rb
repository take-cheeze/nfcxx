#!/usr/bin/env ruby
# encoding: UTF-8
# Regression check for closed-world inherited targets in `&:method` inlining.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SOURCE = <<~'RUBY'
  class SymBase
    def value; 1; end
  end
  class SymChild < SymBase; end
  class SymOther
    def value; 2; end
  end
RUBY

MIXIN_SOURCE = <<~'RUBY'
  module SymMixin
    def value; 3; end
  end
  class SymBase
    def value; 1; end
  end
  class SymChild < SymBase
    include SymMixin
  end
  class SymOther
    def value; 2; end
  end
RUBY

RUNTIME_MIXIN_SOURCE = <<~'RUBY'
  module SymRuntimeMixin
    def value; 3; end
  end
  class SymBase
    def value; 1; end
  end
  class SymChild < SymBase
    def install; extend SymRuntimeMixin; end
  end
  class SymOther
    def value; 2; end
  end
RUBY

def generator_for(source, symbol, dir)
  path = File.join(dir, "#{symbol}.rb")
  File.write(path, source)
  ireps, root = compile_ireps(path, symbol, dir)
  registry, supers, _classes, included, prepended, unknown, _singletons, declarations, walked = build_registry(ireps, root)
  world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: declarations, walked: walked,
                          native_paths: [], ruby_paths: [])
  CodeGen.new(ireps, registry, {}, {}, {}, {}, supers, {}, {}, {}, {}, Set.new, nil, nil, nil,
              included, prepended, unknown, closed_world: world)
end

failures = []
check = lambda do |label, ok|
  if ok
    puts "  ok  #{label}"
  else
    warn "  FAIL #{label}"
    failures << label
  end
end

Dir.mktmpdir do |dir|
  gen = generator_for(SOURCE, 'bc2cpp_sym_inherited', dir)
  kind, branches = gen.sym_call_target('value')
  child = branches.find { |branch| branch[:guard_owner] == 'SymChild' }
  code = gen.sym_call_value('value', 'element', 'result')
  check.call('polymorphic & usage includes a child exact-class branch calling the proven ancestor impl',
             kind == :poly && child && child[:definition].owner == 'SymBase' &&
               code.include?('bc2cpp_owner_class') && code.include?('SymBase') && code.include?('mrb_funcall'))
end

Dir.mktmpdir do |dir|
  gen = generator_for(MIXIN_SOURCE, 'bc2cpp_sym_inherited_mixin', dir)
  _kind, branches = gen.sym_call_target('value')
  check.call('include makes inherited resolution refuse the child branch',
             branches.none? { |branch| branch[:guard_owner] == 'SymChild' })
end

Dir.mktmpdir do |dir|
  gen = generator_for(RUNTIME_MIXIN_SOURCE, 'bc2cpp_sym_runtime_mixin', dir)
  check.call('runtime extend disables inherited closed-world dispatch proofs',
             gen.instance_variable_get(:@closed_world).global_refusal == :dynamic_mixin)
end

if failures.empty?
  puts 'bc2cpp symbol-call inherited check: PASS'
else
  warn "bc2cpp symbol-call inherited check: #{failures.size} failure(s)"
  exit 1
end
