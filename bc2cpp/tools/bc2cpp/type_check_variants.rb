# frozen_string_literal: true

require 'json'

# One immutable input world, with each inference variant continuing in a private fork.
module TypeCheckVariants
  FLAG = '--type-check-variants'
  CONTROL_KEYS = %w[BC2CPP_IR_FRAME_ALLOCATIONS BC2CPP_IR_FIXED_BINDINGS BC2CPP_IR_CONTEXT_REEVALUATION
                    BC2CPP_IR_LEAF_EVALUATIONS BC2CPP_IR_BINDING_INDEX BC2CPP_IR_CALL_INDEX BC2CPP_CLASS_MEMBER_INDEX
                    BC2CPP_IR_CONTEXT_RESULTS BC2CPP_IR_CONTEXT_MAX_CONTEXTS BC2CPP_IR_CONTEXT_MAX_ROUNDS
                    BC2CPP_IR_EFFECT_SUMMARIES BC2CPP_IR_CONTEXT_SHAPES BC2CPP_EXACT_ARITH BC2CPP_OPERATOR_SENDS].freeze
  class Error < RuntimeError; end

  module EnvGuard
    class << self
      attr_accessor :armed
    end
    # The reads that take a key: only one naming a control is refused.
    KEYED = %i[[] fetch key? has_key? include? member? assoc values_at slice []= store delete].freeze
    # Bulk APIs, including counts and exclusion, can observe whether a control exists: CRuby's ENV singleton methods
    # (its own and Enumerable's, as CRuby 4 lists them) other than KEYED, clone, dup, freeze and to_s. Spelled out, not
    # read from ENV.singleton_methods, so a self-compiled bc2cpp's closed world knows the names this module installs
    # (LoopInstallers.unregistered_define_names); arm_guard refuses a Ruby whose ENV has a singleton method neither
    # list names, so a newer Ruby cannot slip past the guard. mruby's ENV (mruby-env) has no singleton methods.
    BULK = %i[
      all? any? chain chunk chunk_while clear collect collect_concat compact count cycle delete_if detect drop
      drop_while each each_cons each_entry each_key each_pair each_slice each_value each_with_index each_with_object
      empty? entries except filter filter! filter_map find find_all find_index first flat_map grep grep_v group_by
      has_value? inject inspect invert keep_if key keys lazy length map max max_by merge! min min_by minmax minmax_by
      none? one? partition rassoc reduce rehash reject reject! replace reverse_each select select! shift size
      slice_after slice_before slice_when sort sort_by sum take take_while tally to_a to_h to_hash to_set uniq update
      value? values zip
    ].freeze
    UNGUARDED = %i[clone dup freeze to_s].freeze

    # A method this Ruby's ENV lacks gets a wrapper too: it only calls super, which raises NoMethodError as before.
    %i[
      [] fetch key? has_key? include? member? assoc values_at slice []= store delete all? any? chain chunk chunk_while
      clear collect collect_concat compact count cycle delete_if detect drop drop_while each each_cons each_entry
      each_key each_pair each_slice each_value each_with_index each_with_object empty? entries except filter filter!
      filter_map find find_all find_index first flat_map grep grep_v group_by has_value? inject inspect invert keep_if
      key keys lazy length map max max_by merge! min min_by minmax minmax_by none? one? partition rassoc reduce rehash
      reject reject! replace reverse_each select select! shift size slice_after slice_before slice_when sort sort_by
      sum take take_while tally to_a to_h to_hash to_set uniq update value? values zip
    ].each do |method|
      define_method(method) do |*args, **opts, &block|
        if EnvGuard.armed && (BULK.include?(method) || args.grep(String).any? { |key| CONTROL_KEYS.include?(key) })
          raise Error, "bc2cpp: shared type-check setup cannot access variant controls through ENV.#{method} before the fork"
        end
        super(*args, **opts, &block)
      end
    end

    def self.uncovered
      ENV.singleton_methods - KEYED - BULK - UNGUARDED
    end
  end

  module_function

  def parse_argv(argv)
    raise Error, 'bc2cpp: only one type-check variants plan is allowed' if argv.count(FLAG) > 1
    index = argv.index(FLAG)
    return nil unless index
    raise Error, 'bc2cpp: shared type-check setup cannot use Ruby preload options' unless ENV['RUBYOPT'].to_s.empty?
    raise Error, "bc2cpp: #{FLAG} needs a plan file" unless argv[index + 1]

    plan = validate_plan(JSON.parse(File.read(argv[index + 1])))
    argv.slice!(index, 2)
    plan
  end

  def validate_plan(entries)
    raise Error, 'bc2cpp: type-check variants need a nonempty array' unless entries.is_a?(Array) && !entries.empty?

    paths = []
    entries.each do |entry|
      unless entry.is_a?(Hash) && entry.keys.sort == %w[env facts stderr]
        raise Error, 'bc2cpp: each type-check variant needs env, facts and stderr'
      end
      env = entry['env']
      unless env.is_a?(Hash) && (env.keys - CONTROL_KEYS).empty? && env.values.all? { |v| v.nil? || v.is_a?(String) }
        raise Error, 'bc2cpp: only registered inference controls may differ between type-check variants'
      end
      %w[facts stderr].each do |key|
        path = entry[key]
        unless path.is_a?(String) && !path.empty? && File.absolute_path(path) == path
          raise Error, "bc2cpp: variant #{key} must be an absolute path"
        end
        paths << path
      end
    end
    raise Error, 'bc2cpp: type-check variant outputs must be distinct' unless paths.uniq.size == paths.size

    entries
  end

  def arm_guard
    uncovered = EnvGuard.uncovered
    unless uncovered.empty?
      raise Error, "bc2cpp: the type-check ENV guard does not cover ENV.#{uncovered.sort.join(', ENV.')}; add them to " \
                   'TypeCheckVariants::EnvGuard'
    end
    ENV.singleton_class.prepend(EnvGuard) unless ENV.singleton_class.include?(EnvGuard)
    EnvGuard.armed = true
  end

  # No child runs concurrently with another. The parent never constructs a CodeGen or runs a variant's exit hooks.
  def fork_variants(entries)
    EnvGuard.armed = false
    $stdout.flush
    $stderr.flush
    entries.each_with_index do |entry, index|
      pid = fork
      if pid.nil?
        entry['env'].each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        ENV['BC2CPP_TYPE_FACTS'] = entry['facts']
        $stdout.reopen(File::NULL, 'w')
        $stderr.reopen(entry['stderr'], 'w')
        $stderr.sync = true
        return
      end
      status = Process.wait2(pid).last
      next if status.success?

      warn "bc2cpp: type-check variant #{index} failed (#{status})"
      warn File.read(entry['stderr']) if File.exist?(entry['stderr'])
      $stderr.flush
      exit!(status.exitstatus || 1)
    end
    exit! 0
  end
end
