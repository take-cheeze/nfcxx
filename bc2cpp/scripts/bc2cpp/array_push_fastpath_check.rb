#!/usr/bin/env ruby
# encoding: UTF-8
# Check exact-Array fast paths for one-argument push/<< and their fallbacks.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class Caller
      def push_one(array, value); array.push(value); end
      def push_many(array, first, second); array.push(first, second); end
      def append(array, value); array << value; end
    end
    class FancyArray < Array
      def push(value); :subclass_push; end
      def <<(value); :subclass_append; end
    end
    class OtherOwner
      def push(value); :owner_push; end
      def <<(value); :owner_append; end
    end
  end
RUBY

ARRAY_OVERRIDE_SRC = SRC + <<~'RUBY'

  class Array
    def push(value); :array_push_override; end
    def <<(value); :array_append_override; end
  end
RUBY

def build_codegen(source_text, symbol, dir)
  source = File.join(dir, "#{symbol}.rb")
  File.write(source, source_text)
  ireps, root_label = compile_ireps(source, symbol, dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  %w[push <<].each do |name|
    registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public)
  end
  owners = Set.new(registry.values.flatten.map(&:owner))
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  class_layout = ClassLayout.known(ClassLayout.analyze(ireps, registry, class_annotations))
  gen = CodeGen.new(ireps, registry, {}, class_layout, class_annotations, {}, {}, {}, {}, {}, {}, Set.new)
  [gen, ireps, registry]
end

def send_code(gen, ireps, registry, method_name, send_name)
  method = registry.fetch(method_name).find { |md| md.owner == 'Game::Caller' }
  raise "Game::Caller##{method_name}: method missing" unless method

  irep = ireps.fetch(method.irep)
  idx = irep.instructions.index { |insn| insn.op.start_with?('SEND') && insn.args.include?(":#{send_name}") }
  raise "Game::Caller##{method_name}: :#{send_name} send missing" unless idx

  gen.compile_send(irep.instructions[idx], self_implicit: false, irep: irep, idx: idx, owner_def: method)
end

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  gen, ireps, registry = build_codegen(SRC, 'bc2cpp_array_push_fastpath', dir)
  push_code = send_code(gen, ireps, registry, 'push_one', 'push')
  check.call('one-argument push uses guarded direct mrb_ary_push and returns the receiver',
             push_code.include?('ARRAY_PUSH :push') && push_code.include?('mrb_array_p(r') &&
               push_code.include?('M->array_class') && push_code.include?('mrb_ary_push(M,') &&
               push_code.match?(/r\d+ = r\d+;/) && push_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/) &&
               push_code.include?('"push", 1'))
  check.call('subclass and unrelated-owner overrides are present for fallback coverage',
             registry.fetch('push').any? { |md| md.owner == 'Game::FancyArray' } &&
               registry.fetch('push').any? { |md| md.owner == 'Game::OtherOwner' } &&
               push_code.include?('mrb_array_p(r') && push_code.include?('M->array_class') &&
               push_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/))

  append_code = send_code(gen, ireps, registry, 'append', '<<')
  # The Integer arm that shares this site sends everything else to the NUMERIC_SLOW_PATH helper (ADR 0292),
  # which holds the by-name call.
  check.call('one-argument << retains its guarded direct Array path and dynamic fallback',
             append_code.include?('ARRAY_PUSH :<<') && append_code.include?('M->array_class') &&
               append_code.include?('mrb_ary_push(M,') && append_code.include?('bc2cpp_slow_lshift(M, '))

  many_code = send_code(gen, ireps, registry, 'push_many', 'push')
  check.call('multi-argument push remains dynamic and does not use mrb_ary_push fast path',
             !many_code.include?('ARRAY_PUSH :push') && !many_code.include?('mrb_ary_push(M,') &&
               many_code.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/) && many_code.include?('"push", 2'))

  override_gen, override_ireps, override_registry = build_codegen(ARRAY_OVERRIDE_SRC,
                                                                   'bc2cpp_array_push_override', dir)
  override_push = send_code(override_gen, override_ireps, override_registry, 'push_one', 'push')
  check.call('bytecode overrides on base Array disable the push fast path',
             !override_push.include?('ARRAY_PUSH :push') && !override_push.include?('mrb_ary_push(M,') &&
               override_push.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M,/) && override_push.include?('"push", 1'))
  override_append = send_code(override_gen, override_ireps, override_registry, 'append', '<<')
  check.call('bytecode overrides on base Array disable the << fast path',
             !override_append.include?('ARRAY_PUSH :<<') && !override_append.include?('mrb_ary_push(M,') &&
               override_append.include?('bc2cpp_slow_lshift(M, '))
end

if failures.empty?
  puts 'bc2cpp Array push fast path check: PASS'
else
  warn "bc2cpp Array push fast path check: #{failures.size} failure(s)"
  exit 1
end
