#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_KEPT report: for each core ROM method-table entry the closed build keeps (CoreNativeCandidates), the first reason
# its name stays. Runs one closed analysis against finished lists, so it needs the same inputs `--emit` does.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_kept_report.rb LISTS.json [--summary] [--runtime]
#   --summary  counts per reason kind instead of one line per entry
#   --runtime  the core run-time registrations instead (native defining calls and core Ruby definitions,
#              CoreNativeCandidates.ram_candidates / ruby_candidates) the build keeps
require_relative '../../tools/bc2cpp/world_root'
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

root = BC2CPP_WORLD_ROOT
path = ARGV.reject { |a| a.start_with?('--') }.first or abort 'usage: core_kept_report.rb LISTS.json [--summary]'
lists = StaticDispatchRegistrations.read_lists(path) or abort "no lists at #{path}"
StaticDispatchRegistrations.core_names = ReasonSet.new
StaticDispatchRegistrations.analyze(root, ENV.fetch('MRBC', 'mrbc'), lists: lists, lists_path: path, closed_only: true)
entries, names, fragments, proven = StaticDispatchRegistrations.core_state
reasons = names.reasons

# Why a kept name stays: the reasons it was read under, a fragment that may build it, or the base of its suffix.
name_reason = lambda do |name|
  if names.include?(name) then Array(reasons[name]).join(' | ')
  elsif (f = fragments.find { |x| x != name && (name.start_with?(x) || name.end_with?(x)) }) then "fragment #{f.inspect}"
  elsif name.end_with?('=', '?', '!') && names.include?(name[0..-2]) then "suffix base #{name[0..-2]} reachable"
  end
end

if ARGV.include?('--runtime')
  _ruby, native = StaticDispatchRegistrations.outside_world_files(root, closed_only: true)
  map = NativeOwnerMap.build(native)
  core = StaticDispatchRegistrations.core_files(root, ENV.fetch('MRBC', 'mrbc'))
  rom = entries.to_set { |e| "#{e[:mt_class]}##{e[:name]}" }
  blocked = Set.new
  map.aliases.each { |owner, new_name, old_name| blocked << "#{owner}##{new_name}" << "#{owner}##{old_name}" }
  map.registrations.each { |owner, name, fn| blocked << "#{owner}##{name}" if fn.nil? }
  keys = {}
  map.registrations.each { |owner, name, _fn| keys[[owner, name]] ||= 'native registration' }
  map.aliases.each { |owner, name, _old| keys[[owner, name]] ||= 'native alias' }
  core.each do |file|
    file[:registry].each do |name, defs|
      defs.each { |d| keys[[d.owner, name]] ||= "Ruby #{File.basename(file[:path])}" if d.irep }
    end
    Array(file[:tuple]&.[](12)).each { |site| keys[[site[:owner], site[:new]]] ||= "Ruby alias #{File.basename(file[:path])}" }
  end
  kept = keys.filter_map do |(owner, name), kind|
    next unless owner.is_a?(String) && name
    next if owner.match?(StaticDispatchRegistrations::CLOSED_OWNER_RE)

    key = "#{owner}##{name}"
    next if lists.core_left_out.include?(key)

    why =
      if !(name.match?(CoreNativeCandidates::NAME) || proven[name]) then 'operator or non-identifier name'
      elsif !owner.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*(?:\.singleton)?\z/) || owner.match?(/\b([A-Z]\w*)::\1\b/)
        'owner not a literal constant path'
      elsif map.computed.include?(owner) then 'computed-name registration on the owner'
      elsif kind.start_with?('native') && blocked.include?(key) then "native alias or undef of the key; name: #{name_reason.call(name) || 'unreachable'}"
      elsif rom.include?(key.sub('.singleton#', '#')) then 'ROM entry of the same class and name'
      else name_reason.call(name) || 'not proven (private or interpreted body)'
      end
    ["#{key} (#{kind})", why]
  end
  if ARGV.include?('--summary')
    kept.group_by { |_k, why| why.split(' | ').map { |w| w.sub(%r{(native|engine irep|live core method|core root or class body|direct _impl call of) .*}, '\\1') }.uniq.join(' | ') }
        .sort_by { |_w, l| -l.size }.each { |w, l| puts "#{l.size.to_s.rjust(5)}  #{w}" }
  else
    kept.sort.each { |key, why| puts "#{key.ljust(48)} #{why.sub(root + '/', '')}" }
  end
  warn "kept #{kept.size} core run-time keys, removed #{lists.core_left_out.size}"
  exit
end

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
