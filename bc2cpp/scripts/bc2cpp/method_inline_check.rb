#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir_inline'

source = <<~RUBY
  class IrInline
    def initialize; @count = 0; end
    def choose(n)
      x = 0
      while x < n
        x += 1
      end
      return false if n < 0
      return nil if n == 0
      return true if n == 1
      @count += x
      [@count, "kept", x, 0.25]
    end
    def nested(n); choose(n); end
    def drive(n); saved = n; a = nested(n); [saved, a, n]; end
    def recursive(n); n == 0 ? 0 : recursive(n - 1); end
    def optional(n = 2); n; end
    def protected(n); n / 0; rescue ZeroDivisionError; 17; end
    def blocky(n); [n].map { |v| v + 1 }; end
    def negative(n); [optional(n), protected(n), blocky(n), recursive(n)]; end
    def chunk(n)
      #{Array.new(20, 'n += 1').join("\n      ")}
      n
    end
    def many(n)
      #{Array.new(35, 'n = chunk(n)').join("\n      ")}
      n
    end
  end
RUBY

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |name, ok|
  puts "#{ok ? 'PASS' : 'FAIL'} #{name}"
  failures << name unless ok
end
wide = Irep.new(nlocals: 1, nregs: 2, pool: [], reps: [], catch_handlers: [],
                instructions: [Insn.new(addr: 0, op: 'JMP', args: '70000'),
                               Insn.new(addr: 70_000, op: 'RETTRUE', args: '')])
wide_region = BytecodeIR::MethodInlineRegion.build(wide, 0)
check.call('IR branch identities have no 16-bit encoding limit', wide_region && wide_region.program.branch_targets.include?(70_000))
unresolved = Irep.new(**wide.to_h.merge(instructions: [Insn.new(addr: 0, op: 'JMP', args: '70001'), wide.instructions.last]))
check.call('unresolved IR branches refuse expansion', BytecodeIR::MethodInlineRegion.build(unresolved, 0).nil?)
generate = lambda do |text, dir, flag|
  previous = ENV['BC2CPP_IR_INLINE']
  begin
    flag ? ENV['BC2CPP_IR_INLINE'] = flag : ENV.delete('BC2CPP_IR_INLINE')
    runtime.generate(text, dir, closed: false, only_owners: ['IrInline'])
  ensure
    previous ? ENV['BC2CPP_IR_INLINE'] = previous : ENV.delete('BC2CPP_IR_INLINE')
  end
end

Dir.mktmpdir('ir-method-inline') do |dir|
  modes = [nil, '0', '1'].map do |flag|
    path = File.join(dir, flag || 'unset')
    Dir.mkdir(path)
    code, err = generate.call(source, path, flag)
    [path, code, err]
  end
  check.call('unset and disabled output are identical', modes[0][1] == modes[1][1])
  code = modes[2][1]
  check.call('typed IR bodies are expanded', code.include?('BYTECODE_IR_INLINE IrInline#nested') && code.include?('BYTECODE_IR_INLINE IrInline#choose'))
  check.call('callee branches use separate symbolic labels', code.match?(/goto bc2cpp_ir_inline_\d+_\d+/))
  check.call('return exits stay inside the inline region', code.match?(/goto bc2cpp_ir_inline_\d+_exit/))
  %w[initialize optional protected blocky recursive].each do |name|
    check.call("#{name} keeps its ordinary call boundary", !code.include?("BYTECODE_IR_INLINE IrInline##{name}\n"))
  end
  many = code.split('mrb_value IrInline_many_impl(', 2).last.to_s.split("\nmrb_value IrInline_many(", 2).first.to_s
  check.call('method budget keeps later calls instead of expanding everything',
             many.scan('BYTECODE_IR_INLINE IrInline#chunk').size.between?(1, 34) && many.include?('IrInline_chunk_impl(M'))

  variants = [modes[0], modes[2]]
  subclass = <<~RUBY
    class IrInlineSub < IrInline
      def choose(n); 404; end
    end
  RUBY
  sub_dir = File.join(dir, 'subclass')
  Dir.mkdir(sub_dir)
  sub_code, sub_err = generate.call(source + subclass, sub_dir, '1')
  check.call('inherited caller still expands a resolved helper', sub_code.include?('BYTECODE_IR_INLINE IrInline#nested'))
  variants << [sub_dir, sub_code, sub_err]
  fiber_dir = File.join(dir, 'fiber')
  Dir.mkdir(fiber_dir)
  fiber_code, = generate.call(source + 'class IrInline; def yielding; Fiber.yield; end; def fiber_driver; yielding; end; end', fiber_dir, '1')
  check.call('Fiber suspension does not enter an inline region', !fiber_code.include?('BYTECODE_IR_INLINE IrInline#yielding'))

  build = runtime.full_or_build
  if build
    body = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value klass = mrb_obj_value(mrb_class_get(M, "IrInline"));
        mrb_value obj = mrb_obj_new(M, mrb_class_ptr(klass), 0, nullptr);
        for (int n : {-1, 0, 1, 3, 7}) {
          mrb_value arg = mrb_fixnum_value(n);
          call(M, "drive", obj, "drive", 1, &arg);
        }
        mrb_value arg = mrb_fixnum_value(3);
        call(M, "negative", obj, "negative", 1, &arg);
        call(M, "many", obj, "many", 1, &arg);
        if (mrb_class_defined(M, "IrInlineSub")) {
          mrb_value sub = mrb_obj_new(M, mrb_class_get(M, "IrInlineSub"), 0, nullptr);
          call(M, "subdrive", sub, "drive", 1, &arg);
        }
        return 0;
      }
    CPP
    variants.each do |path, _, err|
      built, output = runtime.run(path, err, ['IrInline'], body, build: build, full: true)
      check.call("native build/run #{File.basename(path)}", built)
      sections = runtime.sections(output)
      compiled = sections.fetch('compiled', []).reject { |line| line.start_with?('  dispatches=') }
      check.call("native matches interpreter #{File.basename(path)}", !compiled.empty? && compiled == sections['interpreted'])
      if File.basename(path) == 'subclass'
        check.call('inherited entry respects the subclass override', compiled.include?('subdrive => [3, 404, 3]'))
      end
    end
  else
    puts 'SKIP native execution: set BC2CPP_MRUBY_FULL'
  end
end
abort "#{failures.size} method inline checks failed" unless failures.empty?
