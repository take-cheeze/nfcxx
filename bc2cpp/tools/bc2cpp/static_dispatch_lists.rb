# frozen_string_literal: true

# STATIC_DISPATCH_LISTS: the names the closed-list proof (static_dispatch_registrations.rb) leaves out of the method
# tables, computed by `static_dispatch_registrations.rb --emit` and read back by every consumer. They used to be
# three committed files; those went stale after interleaved merges and conflicted in every PR that touched a list.
#
#   open           names safe in every bc2cpp build (Owner#name)
#   closed         the closed build's names, a superset of `open`
#   core_excluded  core ROM method-table entries the closed build leaves out at compile time (MtClass#name)
#   core_left_out  core run-time registrations the closed build removes (Owner#name)
#
# The file named by BC2CPP_STATIC_DISPATCH_LISTS is JSON. Its `digest` is the digest of the proof's inputs, which
# verify_current! compares with the tree. 'none' stands for empty lists: the proof's own first pass, and fixtures
# that are not the engine.
require 'json'
require 'set'

module StaticDispatchLists
  PATH_ENV = 'BC2CPP_STATIC_DISPATCH_LISTS'
  KEYS = %w[open closed core_excluded core_left_out].freeze

  class Missing < StandardError; end

  Lists = Struct.new(:open, :closed, :core_excluded, :core_left_out, :digest, keyword_init: true) do
    # Only the closed build drops the closed-only names.
    def for_build(build_name)
      build_name == 'closed' ? closed : open
    end
  end

  EMPTY = Lists.new(open: Set.new.freeze, closed: Set.new.freeze, core_excluded: Set.new.freeze,
                    core_left_out: Set.new.freeze, digest: 'none').freeze

  module_function

  def parse(text)
    data = JSON.parse(text)
    missing = KEYS - data.keys
    raise Missing, "static dispatch lists lack #{missing.join(', ')}" unless missing.empty?

    Lists.new(**KEYS.to_h { |key| [key.to_sym, data.fetch(key).to_set.freeze] }, digest: data['digest'].to_s).freeze
  end

  def dump(lists)
    JSON.pretty_generate('digest' => lists.digest, **KEYS.to_h { |key| [key, lists.public_send(key).to_a.sort] }) + "\n"
  end

  # The lists a run uses. `required` is true for a real gem build, which must never run without the proof's output:
  # silently registering everything (or leaving everything out) would ship a different method table than the one the
  # proof was run for. Anything else without a path (a check's fixture) gets empty lists.
  def current(required: false, env: ENV)
    path = env[PATH_ENV]
    if path.nil? || path.empty?
      raise Missing, "#{PATH_ENV} is not set; run `ruby tools/bc2cpp/static_dispatch_registrations.rb --emit DIR`" if required

      return EMPTY
    end
    return EMPTY if path == 'none'

    @cache ||= {}
    @cache[path] ||= begin
      raise Missing, "#{PATH_ENV}=#{path} does not exist" unless File.file?(path)

      parse(File.read(path))
    end
  end

  # A file computed from other sources than the tree being built is stale: refuse it, whatever the build would
  # otherwise do with it. 'none' has no digest to compare. Loads the proof only here, so a consumer that does not
  # check (a generator run, which trusts its caller) does not pay for it.
  def verify_current!(lists, repo_root)
    return if lists.equal?(EMPTY)

    require_relative 'static_dispatch_registrations'
    now = StaticDispatchRegistrations.inputs_digest(repo_root)
    return if now == lists.digest

    raise Missing, "#{ENV[PATH_ENV]} was computed for inputs #{lists.digest[0, 12]}, but this tree is #{now[0, 12]}; " \
                   'run scripts/bc2cpp/static_dispatch_lists.bash again'
  end

  def reset!
    @cache = nil
  end
end
