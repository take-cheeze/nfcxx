#!/usr/bin/env ruby
# frozen_string_literal: true

# The numbers of docs/bc2cpp-dynamic-site-census.md, "Follow-up: block loops inside a rescue range (ADR 0376)":
# `mrb_funcall_with_block` sites and generated line counts of two generated C++ files (the shipped pass of
# scripts/bc2cpp/coverage_report.rb, BC2CPP_COVERAGE_KEEP_DIR), in total and for the methods whose protected
# block loops ADR 0376 inlines. A method's functions are its entry, `_impl`, the try bodies, the block
# functions and the inlined-section functions the generator names after it.
#
#   ruby scripts/bc2cpp/rescue_inline_census.rb before/shipped.cxx after/shipped.cxx METHOD...
#
# The METHODs are `Scene::Map` method names, given as arguments: the static-dispatch proof (ADR 0203) counts every
# identifier under scripts/ as a dynamic reference, so a list of engine method names must not live in this file.
#
# The before file is the same tree with BC2CPP_RESCUE_INLINE_BLOCKS=0 BC2CPP_EACH_SPREAD=0 (byte-identical to
# the base commit's output).

OWNER = 'RPG2k__Scene__Map'
DEFINITION = /^(?:static )?(?:mrb_value|void|int|bool) (\w+)\([^;]*\)\s*\{$/

# {function name => lines of its body}, from each definition line to the next one.
def functions(path)
  lines = File.readlines(path, chomp: true)
  starts = lines.each_index.select { |i| lines[i].match?(DEFINITION) }
  starts.each_with_index.to_h do |start, n|
    stop = (starts[n + 1] || lines.size) - 1
    [lines[start][DEFINITION, 1], lines[start..stop]]
  end
end

def owned_by(name, method)
  prefix = "#{OWNER}_#{method}"
  name == prefix || name.match?(/\A#{Regexp.escape(prefix)}(?:_impl|_block_|_inline_|_profiler_)/)
end

abort 'usage: bc2cpp_rescue_inline_census.rb BEFORE.cxx AFTER.cxx METHOD...' if ARGV.size < 3

before, after = ARGV.first(2).map { |path| [path, functions(path)] }
METHODS = ARGV.drop(2).freeze

METRICS = {
  '`mrb_funcall_with_block` sites' => ->(body) { body.count { |l| l.include?('mrb_funcall_with_block') } },
  '`BLOCK_FALLBACK` markers (a block built as an RProc)' => ->(body) { body.count { |l| l.include?('// BLOCK_FALLBACK') } },
  'generated lines' => :size.to_proc,
  'generated functions' => nil
}.freeze

SCOPES = [[nil, 'whole file'], *METHODS.map { |m| [m, "`Scene::Map##{m}`"] }, [:targets, 'the seven methods']].freeze

measure = lambda do |(_path, fns), method, metric, name|
  chosen = method ? fns.select { |fn, _| owned_by(fn, method) } : fns
  next chosen.size unless metric

  chosen.values.sum { |body| name == 'generated lines' ? body.size : metric.call(body) }
end

METRICS.each do |name, metric|
  puts "#{name}:\n\n| Scope | before | after |\n| --- | ---: | ---: |"
  SCOPES.each do |method, label|
    pair = [before, after].map do |side|
      method == :targets ? METHODS.sum { |m| measure.call(side, m, metric, name) } : measure.call(side, method, metric, name)
    end
    puts "| #{label} | #{pair[0]} | #{pair[1]} |"
  end
  puts
end
puts "lines of the whole file: #{File.readlines(before.first).size} before, #{File.readlines(after.first).size} after"
