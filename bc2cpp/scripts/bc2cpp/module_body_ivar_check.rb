#!/usr/bin/env ruby

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_ENV = ENV['MRBC'] || 'mrbc'
failures = []

check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~'RUBY'
  module Body
    @items = Array.new(3, 0)

    def self.clear
      @items.each_index { |i| @items[i] = 0 }
    end
  end

  class << Body
    @other = Array.new(2, 0)
  end

  class Holder
    @items = Array.new(3, 0)

    def self.clear
      @items.each_index { |i| @items[i] = 0 }
    end
  end
RUBY

def body_of(code, function)
  code[/^mrb_value #{function}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'module_body_ivar.rb')
  File.write(source, SOURCE)
  ireps, root_label = compile_ireps(source, 'bc2cpp_module_body_ivar', dir)
  registry, _superclass_of, _containers, _included, _prepended, _unknown, _structs, _classes, _walked,
    module_body_ivar_labels = build_registry(ireps, root_label)
  layout = ClassLayout.known(ClassLayout.analyze(ireps, registry, {}, {}, nil,
                                                  module_body_ivar_labels: module_body_ivar_labels))

  check.call('the registry records module-body ivar writes', module_body_ivar_labels.fetch('Body.singleton').any?)
  check.call('class and singleton-class ivars do not become module-singleton hints',
             !module_body_ivar_labels.key?('Body.singleton') || !module_body_ivar_labels['Body.singleton'].any? { |label| ireps[label].instructions.any? { |insn| insn.op == 'SETIV' && insn.args.include?('@other') } } &&
               !module_body_ivar_labels.key?('Holder.singleton'))
  check.call('module-body Array.new produces an Array class hint', layout.dig('Body.singleton', 'items') == 'Array')
  check.call('class-body ivars do not become class-singleton hints', layout.dig('Holder.singleton', 'items').nil?)
  check.call('singleton-class ivars do not become module-singleton hints', layout.dig('Body.singleton', 'other').nil?)

  env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'module_body_ivar', 'OUT_DIR' => dir,
          'ONLY_OWNERS' => 'Body.singleton,Holder.singleton', 'SKIP_UNSUPPORTED' => '1',
          'BC2CPP_SELF_REGISTERING' => '1' }
  out, err, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, '--annotated', source, chdir: ROOT)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?

  module_body = body_of(out, 'Body_singleton_clear')
  class_body = body_of(out, 'Holder_singleton_clear')
  check.call('the module each_index loop is inlined', module_body.include?('Lbc2cpp_eachidx_iter_') &&
               !module_body.include?('BLOCK_FALLBACK :each_index'))
  check.call('the class singleton fallback remains', class_body.include?('BLOCK_FALLBACK :each_index') &&
               class_body.include?('mrb_funcall_with_block'))
end

if failures.empty?
  puts 'bc2cpp module-body ivar check: PASS'
else
  warn "bc2cpp module-body ivar check: #{failures.size} failure(s)"
  exit 1
end
