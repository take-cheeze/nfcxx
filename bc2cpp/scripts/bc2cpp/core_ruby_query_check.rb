#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/bc2cpp'

# Compare refusals and the ordered live queries, including recursive input sets.
insn_type = Struct.new(:op, :sym, :reg, :argc, :fixed) do
  def plain_fixed_argc? = fixed
end
world_type = Struct.new(:safe) do
  def exact_instances_singleton_free? = safe
end
harness = Class.new(CodeGen) do
  attr_accessor :events, :nil_raises, :captured, :literal_safe, :missing, :unknown
  def nil_unanswerable?(name)
    events << [:nil_raises, name]
    nil_raises
  end
  def captured_local_class_enabled?
    events << :captured
    captured
  end
  def core_ruby_literal_block_safe?(*_args)
    events << :literal
    literal_safe
  end
  def core_ruby_name_result(_irep, _index, insn, arguments)
    events << [:name, insn.sym, arguments]
    NumericFlow::STR
  end
  def core_ruby_result_target(chain, name)
    events << [:target, chain, name]
    chain.first unless missing == chain.first
  end
  def core_ruby_body_result(target, bit, block_given, arguments:, seen:, call_name:)
    events << [:body, target, bit, block_given, arguments, seen.to_a, call_name]
    bit unless unknown == target
  end
end
flags = %w[BC2CPP_CORE_RUBY_QUERY_SCRATCH BC2CPP_CORE_RUBY_RESULTS BC2CPP_CORE_RUBY_POSITIONAL_RESULTS
           BC2CPP_CORE_RUBY_RECEIVER_UNIONS BC2CPP_CORE_RUBY_NESTED_RESULTS]
saved = flags.to_h { |key| [key, ENV[key]] }
begin
  flags.each { |key| ENV.delete(key) }
  cases = 0
  masks = [nil, 0, NumericFlow::OTHER, NumericFlow::INT, NumericFlow::ARR, NumericFlow::HSH,
           NumericFlow::STR | NumericFlow::RNG, NumericFlow::ARR | NumericFlow::NIL,
           CodeGen::RETURN_CORE_MASK, CodeGen::RETURN_CORE_MASK | NumericFlow::OTHER]
  configurations = [{}, { nil_raises: true }, { captured: false }, { literal_safe: false },
                    { missing: 'Array' }, { unknown: 'Array' }, { world: false }, { sources: false },
                    { flag: 'BC2CPP_CORE_RUBY_RESULTS' }, { flag: 'BC2CPP_CORE_RUBY_POSITIONAL_RESULTS' },
                    { flag: 'BC2CPP_CORE_RUBY_RECEIVER_UNIONS' }, { flag: 'BC2CPP_CORE_RUBY_NESTED_RESULTS' }]
  instructions = %i[SEND SEND0 SSEND SSEND0 SENDB SSENDB ADD].product([0, 2], [true, false]).map do |op, argc, fixed|
    insn_type.new(op, 'map', 1, argc, fixed)
  end
  masks.product(configurations, instructions, [true, false], [false, true]).each do |mask, config, insn, name_results, recursive|
    arguments = [nil, mask, NumericFlow::INT, nil].freeze
    seen = recursive ? Set[:ancestor] : nil
    results = %w[0 1].map do |mode|
      ENV['BC2CPP_CORE_RUBY_QUERY_SCRATCH'] = mode
      ENV[config[:flag]] = '0' if config[:flag]
      generator = harness.allocate
      generator.events = []
      generator.nil_raises = config.fetch(:nil_raises, false)
      generator.captured = config.fetch(:captured, true)
      generator.literal_safe = config.fetch(:literal_safe, true)
      generator.missing = config[:missing]
      generator.unknown = config[:unknown]
      generator.instance_variable_set(:@closed_world, world_type.new(config.fetch(:world, true)))
      generator.instance_variable_set(:@native_name_sources, config.fetch(:sources, true))
      keywords = { name_results: name_results }
      keywords[:seen] = seen if seen
      result = generator.core_ruby_class_result(nil, 0, insn, arguments, **keywords)
      raise 'recursive query mutated caller seen' if seen && seen != Set[:ancestor]
      [result, generator.events]
    ensure
      ENV.delete(config[:flag]) if config[:flag]
    end
    raise "core query changed: #{[mask, config, insn, name_results, recursive].inspect}" unless results[0] == results[1]
    cases += 1
  end
  raise 'shared recursion set is mutable' unless CoreRubyResults::EMPTY_SEEN.frozen? && CoreRubyResults::EMPTY_SEEN.empty?
  raise 'shared arguments are mutable' unless CoreRubyResults::EMPTY_ARGUMENTS.frozen? && CoreRubyResults::EMPTY_ARGUMENTS.empty?
  puts "core Ruby query equivalence: #{cases} refusal, ordering, receiver and recursion cases passed"
ensure
  saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
end
