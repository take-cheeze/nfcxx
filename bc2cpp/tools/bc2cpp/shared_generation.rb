# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# SHARED_GENERATION: one whole-program analysis for several generations of the same program.
#
# The compiled gems of a build (mruby-lcf/rpg2k/rgss/core-compiled, tools/bc2cpp/compiled_gems.rb) run bc2cpp.rb over
# the same sources with the same environment except for the keys in UNIT_KEYS: which owners a run emits, the owners
# the other gems emit, where the output goes. Everything bc2cpp.rb does before it reads ONLY_OWNERS (the registry,
# the closed world, the layouts, every fixed point CodeGen.new runs) is therefore the same work, done once per gem.
#
# `bc2cpp.rb --units PLAN srcs...` does it once: the process runs the analysis, then forks one child per unit at the
# point where the first unit key is read. Each child sets its unit's keys, points stdout and stderr at the unit's
# files and continues the main block, so it emits exactly what a separate run with that environment emits; a
# fork shares nothing it could not have computed itself. Nothing is stored between processes, so nothing can go
# stale.
#
# Soundness rests on one fact, which is enforced rather than assumed: before the fork, nothing reads a unit key
# except the two reads at the top (OUT_SYMBOL and OUT_DIR, which only name the scratch .mrb file mrbc writes). A
# read of any unit key between those and the fork raises (EnvGuard), and every run fails.
module SharedGeneration
  FLAG = '--units'
  UNIT_KEYS = %w[OUT_SYMBOL OUT_DIR ONLY_OWNERS OTHER_OWNERS OTHER_DECLS_HEADER].freeze

  class Error < RuntimeError; end

  # A unit: its environment (only UNIT_KEYS; nil unsets) and the files its stdout and stderr go to.
  Unit = Struct.new(:env, :out, :err, keyword_init: true)

  # Raises on a read of a unit key while the guard is armed.
  module EnvGuard
    class << self
      attr_accessor :armed
    end

    %i[[] fetch key? has_key? include? member? assoc values_at slice to_h to_hash each each_pair select filter reject
       filter_map map keys values].each do |name|
      define_method(name) do |*args, **opts, &block|
        if EnvGuard.armed
          touched = args.flat_map { |arg| Array(arg) }.grep(String) & UNIT_KEYS
          touched = UNIT_KEYS if touched.empty? && args.empty?
          unless touched.empty?
            raise Error, "bc2cpp: SHARED_GENERATION: #{touched.join(', ')} read through ENV.#{name} before the per-unit " \
                         'fork; the shared analysis would not be the per-unit one'
          end
        end
        super(*args, **opts, &block)
      end
    end
  end

  module_function

  # [units, rest of argv] when argv starts with FLAG PLAN, else [nil, argv].
  def parse_argv(argv)
    index = argv.index(FLAG)
    return [nil, argv] unless index

    plan = argv[index + 1] or raise Error, "bc2cpp: #{FLAG} needs a plan file"
    [load_plan(plan), argv[0...index] + argv[(index + 2)..]]
  end

  def load_plan(path)
    units = JSON.parse(File.read(path)).map do |entry|
      env = entry.fetch('env')
      stray = env.keys - UNIT_KEYS
      raise Error, "bc2cpp: #{FLAG} plan #{path}: #{stray.join(', ')} may not differ between units" unless stray.empty?

      Unit.new(env: env, out: entry.fetch('out'), err: entry.fetch('err'))
    end
    raise Error, "bc2cpp: #{FLAG} plan #{path} has no units" if units.empty?

    units
  end

  # Before the main block reads anything: the analysis runs under the first unit's keys (only OUT_SYMBOL and
  # OUT_DIR are read before the fork), and everything it prints, mrbc's output included, goes to one prefix file that
  # every unit's stderr starts with.
  # If the process ends before the fork (an abort, an uncaught error), the prefix is all it printed: it is copied to
  # the real stderr and the real stderr restored, so the interpreter's own error report lands there too.
  def start(units)
    apply_env(units.first.env)
    prefix = "#{units.first.err}.prefix"
    saved = $stderr.dup
    $stderr.reopen(prefix, 'w')
    $stderr.sync = true
    parent = Process.pid
    at_exit do
      next unless Process.pid == parent

      $stderr.flush
      saved.write(File.binread(prefix)) if File.exist?(prefix)
      saved.flush
      $stderr.reopen(saved)
      File.delete(prefix) if File.exist?(prefix)
    end
    [prefix, saved]
  end

  def arm_guard
    ENV.singleton_class.prepend(EnvGuard) unless ENV.singleton_class.include?(EnvGuard)
    EnvGuard.armed = true
  end

  def apply_env(env)
    env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Forks one child per unit. Returns the unit in each child, with its environment, stdout and stderr in place; the
  # parent waits for every child, appends each unit's stderr to its own, and exits with the first failure.
  def fork_units(units, prefix, saved_stderr, mrb)
    EnvGuard.armed = false
    $stdout.flush
    $stderr.flush
    pids = units.map do |unit|
      pid = fork
      return enter_unit(unit, prefix, mrb) if pid.nil?

      pid
    end
    statuses = pids.map { |pid| Process.wait2(pid).last }
    File.delete(prefix)
    $stderr.reopen(saved_stderr)
    units.each { |unit| $stderr.write(File.binread(unit.err)) if File.exist?(unit.err) }
    write_failure_trailer(units, statuses)
    $stderr.flush
    failed = statuses.find { |status| !status.success? }
    # exit!: the parent's at_exit hooks (the report writers registered at load) belong to the children, which ran them.
    exit!(failed ? (failed.exitstatus || 1) : 0)
  end

  # A failed unit's errors can sit tens of thousands of lines above the end of the combined stderr (the other units'
  # reports follow it), out of reach of a log viewer that shows only the tail. Repeat them after everything else,
  # with the unit's name and status: its located diagnostics (`file:line:col: error: ...`, printed where found, the
  # abort's "(see above)") and its last lines (where an abort or an uncaught error ends). Printed only on failure, so
  # a passing run's stderr is unchanged.
  TRAILER_ERROR = /: error: /
  TRAILER_ERRORS = 200
  TRAILER_TAIL = 80

  def write_failure_trailer(units, statuses)
    units.zip(statuses).each do |unit, status|
      next if status.success?

      lines = File.exist?(unit.err) ? File.binread(unit.err).scrub.lines.map(&:chomp) : []
      errors = lines.grep(TRAILER_ERROR)
      how = status.exitstatus ? "exit #{status.exitstatus}" : status.to_s
      $stderr.write("\n== --units: unit #{unit.env['OUT_SYMBOL'] || unit.out} failed (#{how}): " \
                    "#{[errors.size, TRAILER_ERRORS].min} of #{errors.size} error line(s), then its last " \
                    "#{[lines.size, TRAILER_TAIL].min} line(s) ==\n")
      (errors.first(TRAILER_ERRORS) + ['--', *lines.last(TRAILER_TAIL)]).each { |line| $stderr.write("#{line}\n") }
    end
  end

  def enter_unit(unit, prefix, mrb)
    apply_env(unit.env)
    # A child's stderr is its own file from here on; the parent's at_exit (pid-checked) does nothing in it.
    File.binwrite(unit.err, File.binread(prefix))
    $stderr.reopen(unit.err, 'a')
    $stderr.sync = true
    $stdout.reopen(unit.out, 'w')
    # The scratch .mrb a separate run leaves in its OUT_DIR.
    symbol, out_dir = mrb
    unit_mrb = File.join(ENV.fetch('OUT_DIR', out_dir), "#{ENV.fetch('OUT_SYMBOL', symbol)}.mrb")
    source_mrb = File.join(out_dir, "#{symbol}.mrb")
    File.binwrite(unit_mrb, File.binread(source_mrb)) unless File.expand_path(unit_mrb) == File.expand_path(source_mrb)
    unit
  end

  # The Ruby-level entry for callers that would otherwise run bc2cpp.rb once per unit: one process over `srcs` with
  # `common_env`, one result per unit (`unit_envs`, each only UNIT_KEYS), as Open3.capture3 returns them:
  # [stdout, stderr, status]. `status` is the shared process's exit status, the same for every unit.
  def run(tool:, srcs:, common_env:, unit_envs:, extra_args: [])
    stray = common_env.keys & UNIT_KEYS
    raise Error, "SharedGeneration.run: #{stray.join(', ')} belong in unit_envs" unless stray.empty?

    Dir.mktmpdir('bc2cpp-shared') do |dir|
      units = unit_envs.each_with_index.map do |env, i|
        { 'env' => env, 'out' => File.join(dir, "#{i}.out"), 'err' => File.join(dir, "#{i}.err") }
      end
      plan = File.join(dir, 'plan.json')
      File.write(plan, JSON.generate(units))
      env = common_env.merge(UNIT_KEYS.to_h { |key| [key, nil] })
      _out, err, status = Open3.capture3(env, RbConfig.ruby, tool, *extra_args, FLAG, plan, *srcs)
      enc = Encoding.default_external
      units.map do |unit|
        out = File.exist?(unit['out']) ? File.binread(unit['out']) : +''
        unit_err = File.exist?(unit['err']) ? File.binread(unit['err']) : err.dup
        [out.force_encoding(enc), unit_err.force_encoding(enc), status]
      end
    end
  end
end
