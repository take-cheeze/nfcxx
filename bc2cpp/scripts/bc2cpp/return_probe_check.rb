#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/bc2cpp'

class ReturnProbeCheck < CodeGen
  attr_reader :embedding_checked

  def drop_unsafe_embeddings(layout)
    @embedding_checked = true
    super
  end
end

[nil, Set.new].each do |foreign|
  registry = Hash.new { |hash, name| hash[name] = [] }
  probe = ReturnProbeCheck.new({}, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                               foreign, analysis_only: :fixnum_return)
  abort 'Fixnum probe should prove nothing in the empty world' unless probe.fixnum_return_names.empty?
  if foreign.nil?
    abort 'a missing scan should skip embedding checks' if probe.embedding_checked
  else
    abort 'a completed empty scan must retain embedding checks' unless probe.embedding_checked
  end
end
puts 'return probe check: PASS'
