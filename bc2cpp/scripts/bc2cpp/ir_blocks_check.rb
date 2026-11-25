#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative '../../tools/mrbc_rb/mrbc_default.rb'

require_relative 'ir_blocks/fixtures'

# Each case gets its own helper namespace and fixture programs; only library loading is shared.
cases = %w[captures rbs_callbacks]
if MrbcRbDefault.from_env
  cases.concat(%w[yields operands])
else
  puts 'SKIP mrbc yield protocol and block operand fixtures (set MRBC)'
end
cases.each do |name|
  puts "== IR blocks: #{name} =="
  load File.join(__dir__, 'ir_blocks', "#{name}.rb"), true
end
puts 'IR block checks passed'
