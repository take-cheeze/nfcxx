#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'open3'
root = File.expand_path('../..', __dir__)
source = File.read(File.join(root, 'tools/bc2cpp/call_context_arguments.rb'))
source = source.sub("require_relative 'numeric_flow'", "require #{File.join(root, 'tools/bc2cpp/numeric_flow.rb').inspect}")
checker = File.read(File.join(__dir__, 'context_arguments_check.rb'))
mutants = {
  'minimum arity' => ['return nil if arguments.size < required + post', '# omitted minimum'],
  'maximum arity' => ['return nil if rest.zero? && arguments.size > required + optional + post', '# omitted maximum'],
  'optional slot' => ['target = index + supplied + 1', 'target = index + 1'],
  'missing optional' => ['Array.new(optional - supplied, NumericFlow::OTHER)', 'Array.new(optional - supplied, NumericFlow::NIL)'],
  'rest class' => ['masks << NumericFlow::ARR', 'masks << NumericFlow::OTHER'],
  'post location' => ['arguments.last(post)', 'arguments.first(post)'],
  'disable switch' => ["ENV['BC2CPP_CONTEXT_ARGUMENT_SHAPES'] == '0'", 'false']
}
Dir.mktmpdir('context-arguments-mutants') do |dir|
  module_path = File.join(dir, 'binding.rb')
  check_path = File.join(dir, 'check.rb')
  File.write(check_path, checker.sub("require_relative '../../tools/bc2cpp/call_context_arguments'", "require #{module_path.inspect}"))
  ([['control', nil]] + mutants.to_a).each do |name, change|
    mutated = source
    if change
      abort "missing mutation #{name}" unless source.include?(change[0])
      mutated = source.sub(*change)
    end
    File.write(module_path, mutated)
    output, status = Open3.capture2e('ruby', check_path)
    ok = change ? !status.success? : status.success?
    abort "FAIL #{name}: #{output}" unless ok
    puts "ok: #{name}"
  end
end
puts 'context argument mutations: PASS'
