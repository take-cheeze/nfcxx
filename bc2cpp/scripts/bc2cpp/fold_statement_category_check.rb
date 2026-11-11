#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_FOLD statement categories (codegen_class_fold.rb, scanned_category): PureEval reads each statement's
# category when a fold has a statement between the constants it reads and the folded one. A `def` there is harmless, so
# the constant still folds. A call with effects there is not, so PureEval refuses the fold. Before this check the
# category read raised NoMethodError on the wrapper. Needs MRBC for the generation half.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'prism'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/pure_eval'

suite = FixtureCheck.new('fold_statement_category_check')
suite.require_mrbc!
check = suite.method(:check)

# B reads A, which is followed by a def before C. The fold needs a constant write directly before B, so C is that write.
HARMLESS = <<~'RUBY'
  class FoldCatOk
    A = 2
    def helper
      1
    end
    C = 3
    B = (0..A).each_with_object({}) { |i, h| h[i] = i }.freeze
  end
RUBY

# The #error lines of the generated code for +source+.
def errors_for(source)
  Dir.mktmpdir('fold_statement_category') do |dir|
    Bc2cppFixtureRuntime.generate(source, dir, path: 'fixture.rb', skip_unsupported: false)
    File.readlines(File.join(dir, 'fixture_gen.cpp')).grep(/#error/)
  end
end

check.call('a def between the read and the folded constant still folds (no #error)',
           errors_for(HARMLESS).empty?)

# Statements built the way CodeGen builds them: one node and one category each. The middle statement is the one
# between the read (A) and the folded constant (B).
Stmt = Struct.new(:node, :category)

def statements_with(middle_source, middle_category)
  nodes = Prism.parse(<<~RUBY).value.statements.body
    A = 2
    #{middle_source}
    C = 3
    B = (0..A).each_with_object({}) { |i, h| h[i] = i }.freeze
  RUBY
  nodes.each_with_index.map { |node, i| Stmt.new(node, i == 1 ? middle_category : :const_literal) }
end

effect_value, effect_why, = PureEval.fold(statements_with('puts "effect"', :dsl_call), 3)
check.call('a call with effects between them is refused by PureEval',
           effect_value.nil? && effect_why.to_s.include?('may change'))

def_value, def_why, = PureEval.fold(statements_with('def helper; 1; end', :def), 3)
check.call('a def between them does not block the fold', !def_value.nil? && def_why.nil?)

suite.finish!
