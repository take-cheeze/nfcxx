#!/usr/bin/env ruby
# frozen_string_literal: true

# Proves a change to tools/bc2cpp/*.rb touches comments only: every file must
# parse to the same Prism AST (node types, literal values, token text; source
# locations and comments ignored) on both sides, with the same magic comments
# and __END__ data. Heredoc and string contents are part of the AST, so the
# C++ templates bc2cpp emits are covered too.
#
# Usage: ruby scripts/bc2cpp/comment_only_check.rb [BASE_REF [HEAD_REF]]
#   BASE_REF defaults to the merge base of origin/master and HEAD (so commits
#   that landed on master after the branch point are not counted);
#   HEAD_REF defaults to the working tree.
# A local tool for comment-only pull requests (see AGENTS.md), not a CI check.

require 'open3'
require 'prism'

ROOT = File.expand_path('../..', __dir__)
GLOB = 'tools/bc2cpp/*.rb'
SEMANTIC_MAGIC = %w[frozen_string_literal encoding coding warn_indent shareable_constant_value].freeze

def git(*args)
  out, err, status = Open3.capture3('git', '-C', ROOT, *args)
  abort "git #{args.join(' ')} failed:\n#{err}" unless status.success?
  out
end

base_ref = ARGV[0] || git('merge-base', 'origin/master', 'HEAD').strip
head_ref = ARGV[1]

def files_at(ref)
  if ref
    git('ls-tree', '--name-only', ref, 'tools/bc2cpp/').lines.map(&:chomp).grep(/\.rb\z/)
  else
    Dir.glob(GLOB, base: ROOT).sort
  end
end

def source_at(ref, path)
  if ref
    git('show', "#{ref}:#{path}")
  else
    File.read(File.join(ROOT, path), encoding: 'UTF-8')
  end
end

# Flattens the tree into [token, line] pairs. Only the token is compared; the
# line is there to point at the difference.
def fingerprint(node, out = [])
  line = node.location.start_line
  out << ["#{node.class.name.split('::').last}(", line]
  # `__LINE__` is the one node whose value is its location.
  out << ["line=#{line}", line] if node.is_a?(Prism::SourceLineNode)
  node.deconstruct_keys(nil).each do |key, value|
    next if key == :location

    out << ["#{key}:", line]
    emit(value, line, out)
  end
  out << [')', line]
end

def emit(value, line, out)
  case value
  when Prism::Node then fingerprint(value, out)
  # A multi-line location can span comments (`Set[ ... ]`'s message_loc covers
  # the whole bracket list); its content is compared through the child nodes.
  when Prism::Location
    slice = value.slice
    out << [slice.include?("\n") ? 'loc=<multi-line>' : "loc=#{slice.inspect}", line]
  when Array
    out << ['[', line]
    value.each { |v| emit(v, line, out) }
    out << [']', line]
  else out << [value.inspect, line]
  end
end

def comment_lines(result)
  result.comments.sum { |c| c.location.end_line - c.location.start_line + 1 }
end

def summarize(src)
  result = Prism.parse(src)
  {
    result: result,
    lines: src.lines.size,
    bytes: src.bytesize,
    comment_lines: comment_lines(result)
  }
end

label = head_ref || 'working tree'
paths = (files_at(base_ref) | files_at(head_ref)).sort
failures = []
puts "bc2cpp comment-only check: #{base_ref} -> #{label}"
paths.each do |path|
  base_files = files_at(base_ref)
  head_files = files_at(head_ref)
  unless base_files.include?(path) && head_files.include?(path)
    failures << "#{path}: only on one side"
    next
  end
  before_src = source_at(base_ref, path)
  after_src = source_at(head_ref, path)
  next if before_src == after_src

  before = summarize(before_src)
  after = summarize(after_src)
  problems = []
  [[before, base_ref], [after, label]].each do |s, side|
    s[:result].errors.each { |e| problems << "parse error on #{side}: #{e.message} (line #{e.location.start_line})" }
  end
  # Prism reports every `# word: value` comment as a magic comment; only the
  # ones Ruby acts on matter.
  magic = lambda do |s|
    s[:result].magic_comments.map { |m| [m.key.downcase.tr('-', '_'), m.value] }
             .select { |k, _| SEMANTIC_MAGIC.include?(k) }
  end
  problems << 'magic comments differ' if magic.call(before) != magic.call(after)
  data = ->(s) { s[:result].data_loc&.slice }
  problems << '__END__ data differs' if data.call(before) != data.call(after)
  a = fingerprint(before[:result].value)
  b = fingerprint(after[:result].value)
  if a.map(&:first) != b.map(&:first)
    i = a.zip(b).index { |x, y| x.nil? || y.nil? || x.first != y.first } || [a.size, b.size].min
    problems << "AST differs near #{base_ref} line #{a[i]&.last} / #{label} line #{b[i]&.last}: " \
                "#{a[i]&.first.to_s[0, 200].inspect} vs #{b[i]&.first.to_s[0, 200].inspect}"
  end
  status = problems.empty? ? 'ok  ' : 'FAIL'
  puts format('  %s %-48s lines %6d -> %6d  bytes %8d -> %8d  comment lines %6d -> %6d',
              status, path, before[:lines], after[:lines], before[:bytes], after[:bytes],
              before[:comment_lines], after[:comment_lines])
  problems.each { |p| puts "       #{p}" }
  failures.concat(problems.map { |p| "#{path}: #{p}" })
end

if failures.empty?
  puts 'bc2cpp comment-only check: PASS'
else
  warn "bc2cpp comment-only check: #{failures.size} failure(s)"
  exit 1
end
