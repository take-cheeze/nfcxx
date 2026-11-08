#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_KEPT report: for each core ROM method-table entry the closed build keeps (CoreNativeCandidates), the first reason
# its name stays. Runs one closed analysis against finished lists, so it needs the same inputs `--emit` does.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_kept_report.rb LISTS.json [--summary]
#   --summary  counts per reason kind instead of one line per entry
require 'set'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

# A Set that remembers the labels (see CoreNativeCandidates.reachable's `note`) under which each name arrived, first six.
class ReasonSet < Set
  attr_reader :reasons

  def initialize(*)
    super
    @reasons = {}
    @label = 'unknown'
  end

  def note(label)
    @label = label.sub(/\Aengine irep .*/, 'engine irep').sub(%r{\Anative .*/3rd/(mruby/(?:mrbgems/)?)?}, 'native ')
  end

  def add(name)
    labels = (@reasons[name] ||= [])
    labels << @label unless labels.include?(@label) || labels.size >= 6
    super
  end
  # Set aliases << to its own add, so it needs the same wrapper.
  alias << add
end

root = File.expand_path('../..', __dir__)
path = ARGV.reject { |a| a.start_with?('--') }.first or abort 'usage: core_kept_report.rb LISTS.json [--summary]'
lists = StaticDispatchRegistrations.read_lists(path) or abort "no lists at #{path}"
StaticDispatchRegistrations.core_names = ReasonSet.new
StaticDispatchRegistrations.analyze(root, ENV.fetch('MRBC', 'mrbc'), lists: lists, lists_path: path, closed_only: true)
entries, names, fragments, proven = StaticDispatchRegistrations.core_state
reasons = names.reasons

kept = entries.group_by { |e| [e[:mt_class], e[:name] || "OPSYM #{e[:cname]}"] }.filter_map do |(mt_class, name), group|
  key = "#{mt_class}##{name}"
  next if lists.core_excluded.include?(key)

  why =
    if !(name.match?(CoreNativeCandidates::NAME) || proven[name]) then 'operator or non-identifier name'
    elsif !group.all? { |e| e[:installed] } then 'table shared with another class'
    elsif names.include?(name) then Array(reasons[name]).join(' | ')
    elsif (f = fragments.find { |x| x != name && (name.start_with?(x) || name.end_with?(x)) }) then "fragment #{f.inspect}"
    else 'suffix base reachable'
    end
  [key, why]
end

if ARGV.include?('--summary')
  kept.group_by { |_k, why| why.split(' | ').map { |w| w.sub(%r{(native|engine irep|live core method|core root or class body) .*}, '\\1') }.uniq.join(' | ') }
      .sort_by { |_w, l| -l.size }.each { |w, l| puts "#{l.size.to_s.rjust(5)}  #{w}" }
else
  kept.sort.each { |key, why| puts "#{key.ljust(36)} #{why.sub(root + '/', '')}" }
end
warn "kept #{kept.size} core ROM keys, excluded #{lists.core_excluded.size}"
