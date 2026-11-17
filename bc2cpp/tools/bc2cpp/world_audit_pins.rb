# frozen_string_literal: true

require 'yaml'
require_relative 'world_root'

# Audit pins for the engine sources the world repository owns (mruby-rgss). Their digests change with those sources, so
# they are read from sig/bc2cpp/audit_pins.yml in the world, not kept in this tree. A world without the file has no such
# pins: the audits skip those sources and withhold their facts, which is the safe side.
module WorldAuditPins
  PATH = File.join(BC2CPP_WORLD_ROOT, 'sig/bc2cpp/audit_pins.yml')
  DATA = File.file?(PATH) ? YAML.safe_load_file(PATH) : {}

  module_function

  def ivar_files
    DATA.fetch('ivar_scopes', {}).to_h { |path, digest| [path, digest] }
  end

  def class_result_files
    DATA.fetch('class_results', {}).fetch('files', {}).to_h { |path, digest| [path, digest] }
  end

  # The world adds spellings to the tree's facts: a fact the tree has keeps its kind, and the world's paths follow
  # the tree's. A fact the tree lacks is added whole.
  def merge_facts(base)
    DATA.fetch('class_results', {}).fetch('facts', {}).each_with_object(base.dup) do |(name, spec), facts|
      kind = spec.fetch('kind')
      kind = kind.map { |part| part.nil? ? :nil : part } if kind.is_a?(Array)
      paths = spec.fetch('paths')
      if facts.key?(name)
        tree_kind, tree_paths = facts.fetch(name)
        raise ArgumentError, "#{PATH}: fact #{name} kind #{kind.inspect} differs from #{tree_kind.inspect}" unless tree_kind == kind

        facts[name] = [tree_kind, tree_paths + paths].freeze
      else
        facts[name] = [kind, paths].freeze
      end
    end.freeze
  end
end
