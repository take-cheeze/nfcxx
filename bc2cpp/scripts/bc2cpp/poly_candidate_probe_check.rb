#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'check_support'

suite = FixtureCheck.new('poly_candidate_probe_check')
suite.require_mrbc!

source = <<~RUBY
  class NoArgs
    def value; 0; end
  end
  class OneArg
    def value(arg); arg; end
  end
  class OptionalArg
    def value(arg = 1); arg; end
  end
RUBY

suite.compile(source) do |ireps, root, _dir|
  registry = build_registry(ireps, root).first
  generator = CodeGen.allocate
  generator.instance_variable_set(:@registry, registry)
  generator.instance_variable_set(:@ireps, ireps)
  generator.define_singleton_method(:devirt_blocked_name?) { |_name| false }
  probes = []
  unclean = nil
  generator.define_singleton_method(:compiles_clean?) do |label|
    definition = registry['value'].find { |candidate| candidate.irep == label }
    probes << definition.owner
    definition.owner != unclean
  end

  candidates = generator.poly_candidates('value', 1)
  suite.check('mandatory chains retain only the matching signature', candidates.map(&:owner) == ['OneArg'])
  suite.check('mandatory chains never probe incompatible mandatory or optional bodies', probes == ['OneArg'])

  probes.clear
  candidates = generator.poly_candidates('value', 1, optional: true)
  suite.check('optional chains retain mandatory and optional signatures', candidates.map(&:owner) == %w[OneArg OptionalArg])
  suite.check('optional chains never probe an incompatible mandatory body', probes == %w[OneArg OptionalArg])

  probes.clear
  unclean = 'OneArg'
  suite.check('a matching but unclean body still cannot enter the chain', generator.poly_candidates('value', 1).nil?)
  suite.check('refusing an unclean body does not probe an incompatible body', probes == ['OneArg'])

  probes.clear
  suite.check('a call outside every signature has no candidates', generator.poly_candidates('value', 3, optional: true).nil?)
  suite.check('a call outside every signature performs no cleanliness probes', probes.empty?)
end

suite.finish!
