#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_FOLD (tools/bc2cpp/codegen_class_fold.rb): a constant a class body builds with a block is folded at build time
# (PureEval) and its value is emitted as C++ in place of the block. A folded value compiles with the mruby headers; a
# constant PureEval does not fold leaves its body refused. Needs MRBC and g++; without MRBC it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_fold_check.rb

require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('class_body_fold_check')
suite.require_mrbc!

FOLDED = <<~'RUBY'
  class Router
    SFX = (0..3).each_with_object({}) { |slot, h| h[slot] = 91 + slot }.freeze
  end
RUBY

UNFOLDABLE = <<~'RUBY'
  class Router
    NAMES = [1].each { |a| puts a }
  end
RUBY

suite.compile(FOLDED) do |ireps, root|
  body = ireps.values.find { |irep| BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :SETCONST } }
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('a block-built constant that folds compiles, with the folded hash in place of the block',
              code.include?('mrb_hash_set(M, fold') && !code.include?('#error'))
  unit = +"#{%w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h].map { |h| "#include <#{h}>\n" }.join}#{gen.emit_owner_class_cache}"
  unit << units.map { |u| u[:code] }.join
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_fold_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the folded unit compiles with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.compile(UNFOLDABLE) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  suite.check('a block-built constant that does not fold refuses its body',
              gen.compile_top_class_units(ireps.fetch(root)).empty?)
end

suite.finish!
