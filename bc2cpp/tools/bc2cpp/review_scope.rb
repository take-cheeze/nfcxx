# frozen_string_literal: true

# REVIEW_SCOPE: which compiled methods the reviewed lists judge. NOMETHOD_REVIEWED (ADR 0226),
# PROVEN_MISS_REVIEWED (ADR 0275) and STRICT_HINTS_REVIEWED (ADR 0419) are reviews of one program:
# the engine, i.e. the methods the gems of BC2CPP_COMPILED_GEMS compile. Their keys are
# "<compiled owner>#<compiled method> -> ...", and every owner they name is one of those gems' owners.
#
# On an engine closed-world build (psp, wio, maix) a site is held to the lists when its compiled
# owner is an engine owner, matched exactly. Nothing is skipped on a real engine build: each gem's
# ONLY_OWNERS is its BC2CPP_COMPILED_GEMS owners, and the only other owner compile_all emits is the
# module whose module_function body a selected `X.singleton` copy shares (owner `X`), which the scope
# includes; bc2cpp.rb aborts if an engine-owner run ever compiles an owner outside it. A fixture
# program compiled with the wio world (classes such as TcUse) is not the program the lists review,
# so its sites are listed but not judged by them.
#
# Every other closed-world build is held to every owner: optcarrot-probe is a different program with no
# reviewed sites of its own, so any site it has fails it; the sealed desktop host (`host`) compiles only
# engine owners, so every owner is the same set there.
require 'set'
# A mutant copy of tools/bc2cpp beside the repository's own compiled_gems.rb must not define its constants twice.
require_relative 'compiled_gems' unless defined?(BC2CPP_COMPILED_GEMS)

module ReviewScope
  ALL = :all
  # The closed-world builds whose program is the engine (compiled_gems.rb: their closed world is
  # BC2CPP_CLOSED_WORLD_GEMS; optcarrot-probe's is the Optcarrot benchmark).
  ENGINE_BUILDS = (BC2CPP_CLOSED_WORLD_BUILDS - %w[optcarrot-probe]).freeze
  # The engine owners, plus the module of each `X.singleton` owner (a module_function copy's shared
  # body is compiled under the module's own owner, e.g. LCF for LCF.singleton).
  ENGINE_OWNERS = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }.then do |owners|
    (owners + owners.filter_map { |o| o.delete_suffix('.singleton') if o.end_with?('.singleton') }).to_set
  end.freeze

  module_function

  # The scope a closed-world run of build `build_name` is held to: ENGINE_OWNERS or ALL.
  def for_build(build_name)
    ENGINE_BUILDS.include?(build_name) ? ENGINE_OWNERS : ALL
  end

  def cover?(scope, owner)
    scope == ALL || scope.include?(owner)
  end

  # The owner of a list key "<owner>#<method> -> ..." (owners never contain '#').
  def key_owner(key)
    key.split('#', 2).first
  end

  # The sites of `sites` ({key:, ...}) the scope judges.
  def select(scope, sites)
    scope == ALL ? sites : sites.select { |s| scope.include?(key_owner(s[:key])) }
  end

  # Why an engine-owner run compiled an owner outside the scope (empty when it did not): a run whose
  # ONLY_OWNERS are all engine owners is a real gem run, and every method it compiles must be judged.
  def leaks(scope, only_owners, compiled)
    return [] if scope == ALL || only_owners.nil? || !only_owners.all? { |o| scope.include?(o) }

    compiled.map { |m| m[:owner] }.uniq.reject { |o| scope.include?(o) }.sort
  end
end
