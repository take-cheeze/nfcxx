#!/usr/bin/env ruby
# frozen_string_literal: true

# METHOD_TABLE_MODEL: the method-table entries the closed build is expected to install, read from the sources
# the way bc2cpp reads them (mrbc IR, build_registry), with every site it cannot resolve kept as an unknown.
#
# Per gem root (ClassWorldGate.closed_roots, in load order):
#   known    a definition the registry resolves to one owner and one name: a bytecode def, or a native (`<native>`)
#   derived  a definition an installer created (alias, module_function copy, attr accessor, loop installer), with
#            the installer kind
#   unknown  a site whose name or owner the registry could not resolve: an unknown mixin, an alias whose source
#            or name is not a literal, and a method installed by a dynamic call
#
# The output is JSON, to compare later with the closed host's own method-table count
# (BC2CPP_HOST_MT_COUNT=1, scripts/bc2cpp/trace_host.cxx). Entries are not deduplicated across roots: a name a
# later root redefines appears under both, and `redefined` marks it.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/method_table_model.rb [OUT.json]

require 'json'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/class_world_gate'

ROOT = File.expand_path('../..', __dir__)

def entry(name, defn)
  { owner: defn.owner, name: name, kind: defn.kind&.to_s, installer: defn.installer&.to_s,
    visibility: defn.visibility&.to_s, core: defn.core ? true : false }.compact
end

def model_root(label, files, scratch)
  ireps, root_label = compile_ireps(files, label.gsub(/[^a-zA-Z0-9_]/, '_'), scratch)
  registry, _superclass_of, _container, _included, _prepended, unknown_mixins, *_rest, alias_sites =
    build_registry(ireps, root_label)

  known = []
  derived = []
  registry.each do |name, defs|
    defs.each do |defn|
      next if defn.owner.nil?

      if defn.installer.nil?
        known << entry(name, defn)
      else
        derived << entry(name, defn)
      end
    end
  end

  unknown = []
  Array(unknown_mixins).each { |owner| unknown << { site: 'unknown mixin', owner: owner.to_s } }
  Array(alias_sites).each do |site|
    unknown << { site: 'alias', owner: site[:owner], new: site[:new], old: site[:old] } if site[:new].nil? || site[:old].nil?
  end

  by_name = Hash.new(0)
  known.each { |e| by_name[e[:name]] += 1 }
  redefined = by_name.select { |_name, count| count > 1 }.keys.to_set
  known.each { |e| e[:redefined] = true if redefined.include?(e[:name]) }

  { known: known, derived: derived, unknown: unknown }
end

out = ARGV[0]
roots = ClassWorldGate.closed_roots(ROOT)
report = { roots: {}, totals: Hash.new(0) }

Dir.mktmpdir('method-table-model') do |scratch|
  roots.each do |label, files|
    model = model_root(label, files, scratch)
    report[:roots][label] = model
    model.each { |kind, list| report[:totals][kind] += list.size }
  end
end

report[:totals] = report[:totals].to_h
json = JSON.pretty_generate(report)
if out
  File.write(out, json)
  warn "method_table_model: wrote #{out}"
else
  puts json
end
puts "totals: #{report[:totals].map { |k, v| "#{k} #{v}" }.join(', ')}" if out
