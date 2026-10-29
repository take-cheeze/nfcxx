# frozen_string_literal: true

require_relative 'compiled_gems'
require_relative 'class_body_scan'
require_relative 'class_world'

# CLASS_WORLD_GATE: the class graph code generation reads. ClassWorld (class_world.rb) states the graph from the
# mrblib sources of the closed build; this file names those sources (the same roots scripts/bc2cpp/class_body_report.rb
# reports on) and answers one question: is a receiver class exact, with every ancestor exact too. Nothing is written
# to disk; the graph is derived from the sources once per process.
#
# The gate refuses, never guesses: a class the graph does not know, a class with any ancestor that is not exact, and
# a build that cannot derive the graph all answer false. BC2CPP_CLASS_WORLD_DIRECT=0 turns the direct forms that
# read the gate off, so the output is the one from before the gate.
module ClassWorldGate
  module_function

  # The mrblib roots of the closed build, in load order: [name, files]. `root` is the repository root.
  def closed_roots(root)
    mruby = "#{root}/3rd/mruby"
    core = bc2cpp_closed_core_gems(root).map { |g| File.basename(g) }
    roots = [['core:mrblib', Dir["#{mruby}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') }]]
    BC2CPP_CORE_MRBLIB_GEMS.each do |gem|
      next unless core.include?(gem)

      files = Dir["#{mruby}/mrbgems/#{gem}/mrblib/**/*.rb"].sort.reject { |p| p.end_with?('mruby-io/mrblib/kernel.rb') }
      roots << ["core:#{gem}", files] unless files.empty?
    end
    roots << ['ext:mruby-stringio', Dir["#{root}/3rd/mruby-stringio/mrblib/**/*.rb"].sort]
    rpg2k = Dir["#{root}/mruby-rpg2k/mrblib/**/*.rb"].reject { |p| p.end_with?('scene/map_tts.rb') }.sort
    roots << ['engine:mruby-rpg2k', rpg2k + ["#{root}/mruby-rpg2k/mrblib_limited/map_tts_off.rb"]]
    roots << ['engine:mruby-lcf', Dir["#{root}/mruby-lcf/mrblib/*.rb"].sort]
    roots << ['engine:mruby-rgss', Dir["#{root}/mruby-rgss/mrblib/*.rb"].sort]
    roots.reject { |_, files| files.empty? }
  end

  REPO_ROOT = File.expand_path('../..', __dir__)

  # The ClassWorld of the closed build, built once per process from the sources (ClassWorld.build over every root's
  # scan, in load order). Returns the World, or nil when the graph cannot be derived.
  def world
    return @world if defined?(@world)

    @world = begin
      scans = closed_roots(REPO_ROOT).map { |_, files| ClassBodyScan.scan(files) }
      ClassWorld.build(scans)
    rescue StandardError
      nil
    end
  end

  # Gate: `klass` is exactly modeled in ClassWorld and so is every ancestor of it (the owner's ancestors included,
  # since a direct call to an owner's body is only as exact as the chain that reaches it). Unknown names are refused.
  def exact_receiver?(klass, world = self.world)
    return false unless world && klass.is_a?(String)

    facts = world.facts
    fact = facts[klass]
    return false unless fact && fact['exact']

    fact['ancestors'].all? { |anc| facts[anc] && facts[anc]['exact'] }
  end

  # The ancestors of `klass` in lookup order, or nil when the gate refuses the class.
  def exact_ancestors(klass, world = self.world)
    exact_receiver?(klass, world) ? world.facts[klass]['ancestors'] : nil
  end

  def enabled? = ENV['BC2CPP_CLASS_WORLD_DIRECT'] != '0'
end
