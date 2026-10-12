#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CodeGen#aliased_operand_names (docs/adr/0370): the names `alias`, `alias_method` and `define_method` spell as
# Symbol literals, which an attr_reader of a checked pool is withdrawn by instead of by every Symbol of the irep
# (numeric_aliased_names, unchanged for every other name). An operand that is not a literal gives nil.
#
# Usage: ruby scripts/bc2cpp/aliased_names_check.rb   (needs a host mrbc: MRBC=path)

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class AlLiteral
    attr_reader :al_keep, :al_other
    def al_orig; 1; end
    alias al_kw al_orig
    alias_method :al_meth, :al_orig
    define_method(:al_def) { 2 }
  end

  class AlComputed
    attr_reader :ac_keep
    def ac_orig; 1; end
    alias_method "ac_\#{1}".to_sym, :ac_orig
  end

  class AlNone
    attr_reader :an_keep
  end
RUBY

unless ENV['MRBC']
  puts '-- SKIP: set MRBC'
  exit 0
end

ireps, = Dir.mktmpdir do |dir|
  path = File.join(dir, 'aliased.rb')
  File.write(path, SOURCE)
  parsed, root_label = compile_ireps(path, 'bc2cpp_aliased', dir)
  [parsed, build_registry(parsed, root_label)[0]]
end
gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
per_irep = ireps.values.to_h { |irep| [irep.label, gen.aliased_operand_names(irep)] }
literal = per_irep.values.compact.reduce(Set.new, :|)
coarse = gen.numeric_aliased_names

check.call('the names an alias, alias_method and define_method spell are the operands',
           %w[al_kw al_orig al_meth al_def].all? { |n| literal.include?(n) })
check.call('an attr_reader in the same class body is not an operand', !literal.include?('al_keep') && !literal.include?('al_other'))
check.call('the coarse set (every Symbol of the irep) still holds it, so only a checked accessor name uses the operands',
           coarse.include?('al_keep') && coarse.include?('al_orig'))
check.call('NEG a computed alias_method has no operand list: the caller keeps the coarse set for that irep',
           per_irep.values.count(&:nil?) == 1 && coarse.include?('ac_orig') && coarse.include?('ac_keep'))
check.call('a class body with no aliasing operation contributes nothing', !coarse.include?('an_keep') && !literal.include?('an_keep'))

if failures.empty?
  puts 'bc2cpp aliased names check: PASS'
else
  warn "bc2cpp aliased names check: #{failures.size} failure(s)"
  exit 1
end
