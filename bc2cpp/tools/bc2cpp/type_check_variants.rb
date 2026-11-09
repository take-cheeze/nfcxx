# frozen_string_literal: true

require 'json'

# One immutable input world, with each inference variant continuing in a private fork.
module TypeCheckVariants
  FLAG = '--type-check-variants'
  CONTROL_KEYS = %w[BC2CPP_IR_FRAME_ALLOCATIONS BC2CPP_IR_FIXED_BINDINGS BC2CPP_IR_CONTEXT_REEVALUATION
                    BC2CPP_IR_LEAF_EVALUATIONS BC2CPP_IR_BINDING_INDEX BC2CPP_IR_CALL_INDEX BC2CPP_CLASS_MEMBER_INDEX
                    BC2CPP_IR_CONTEXT_RESULTS BC2CPP_IR_CONTEXT_MAX_CONTEXTS BC2CPP_IR_CONTEXT_MAX_ROUNDS
                    BC2CPP_IR_EFFECT_SUMMARIES BC2CPP_IR_CONTEXT_SHAPES].freeze
  class Error < RuntimeError; end

  module EnvGuard
    class << self
      attr_accessor :armed
    end
    keyed = %i[[] fetch key? has_key? include? member? assoc values_at slice []= store delete]
    # Bulk APIs, including counts and exclusion, can observe whether a control exists.
    all = ENV.singleton_methods - keyed - %i[clone dup freeze to_s]
    (keyed + all).each do |method|
      next unless ENV.respond_to?(method)

      define_method(method) do |*args, **opts, &block|
        if EnvGuard.armed && (all.include?(method) || args.grep(String).any? { |key| CONTROL_KEYS.include?(key) })
          raise Error, "bc2cpp: shared type-check setup cannot access variant controls through ENV.#{method} before the fork"
        end
        super(*args, **opts, &block)
      end
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
