#!/usr/bin/env ruby
# frozen_string_literal: true

# Wrapped loads keep case helpers and constants private while sharing library loading.
%w[exact_types container_shapes numeric_classes return_sites origin_transfers dataflow_seen].each do |name|
  puts "== IR facts: #{name} =="
  load File.join(__dir__, 'ir_facts', "#{name}.rb"), true
end
puts 'IR fact checks passed'
