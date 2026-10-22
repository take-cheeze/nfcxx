# frozen_string_literal: true

require 'set'
require_relative 'core_defs'

# CORE_METHODS: every method of mruby's own Ruby (compiled_gems.rb
# BC2CPP_CORE_MRBLIB_GEMS) that compiles clean is compiled, except the ones that
# stay bytecode by decision: a definition a later one replaces, one a
# conditional can skip, one that names the Fiber class or builds a lambda (CoreDefs),
# and the `Owner#name` entries of core_refused.txt. A method that touches a block
# compiles behind the Fiber guard (guarded_labels). An excluded definition is
# dropped from the registry (bc2cpp.rb), so it is neither compiled nor a dispatch
# target, and the interpreter's method answers it exactly as before.
module CoreMethods
  DEFAULT_PATH = File.expand_path('core_refused.txt', __dir__)
  # The operator names bc2cpp gives inline fast paths (fixnum arithmetic and comparison,
  # `case`/`when` literals, INTEGER_UNARY) on the premise that the registry holds only
  # the native definition of the name (CodeGen#native_only_mono?, eqq_literal_devirt_safe?).
  # A core Ruby definition of one (Comparable#<, Numeric#-@, String#%) sits behind the
  # builtin receivers' own natives and can never win, but showing it to the registry
  # would switch those fast paths off, so it is compiled without being a registry
  # definition (bc2cpp.rb CORE_VISIBILITY).
  OPERATOR_NAMES = %w[+ - * / % ** & | ^ ~ << >> < <= > >= == != === <=> =~ !~ ! [] []= -@ +@ zero?].freeze

  module_function

  # Admits an Enumerator method by its body alone, not by name: the body must come from
  # mruby-enumerator's enumerator.rb and touch no block and no Fiber. In that file only
  # inspect, size, rewind, feed, next, peek and peek_values pass (next_values names Fiber,
  # the rest take a block). These wrappers create no compiled closure. Their delegated
  # callbacks may suspend, so every entry still requires the root context.
  def enumerator_wrapper?(definition, ireps)
    return false if ENV['BC2CPP_ENUMERATOR_WRAPPERS'] == '0'
    return false unless definition && definition.owner == 'Enumerator'

    body = definition.irep && ireps[definition.irep]
    body && body.file.to_s.end_with?('/mruby-enumerator/mrblib/enumerator.rb') &&
      !CoreDefs.touches_block?(body, ireps) && !CoreDefs.references_fiber?(body, ireps)
  end

  # The listed "Owner#name" keys of core_refused.txt. Raises on a line that is not one entry.
  def load_refused(path = DEFAULT_PATH)
    File.readlines(path, chomp: true).each_with_index.with_object(Set.new) do |(line, i), set|
      entry = line.strip
      next if entry.empty? || entry.start_with?('#')

      entry = entry.split(/\s+#/, 2).first
      raise ArgumentError, "#{path}:#{i + 1}: not an Owner#name entry: #{line.inspect}" unless entry.match?(/\A[A-Z][\w:]*(?:\.singleton)?#\S+\z/)

      set << entry
    end
  end

  def key(method_def)
    "#{method_def.owner}##{method_def.name}"
  end

  # Irep labels of the core-source definitions in `registry` that must not be
  # compiled: refused, conditional, Fiber-naming, lambda-building or unaudited mruby-enumerator bodies
  # (shadowed ones are dropped from the registry by the driver before this runs).
  def excluded_labels(registry, ireps, refused)
    conditional = CoreDefs.conditional_def_labels(ireps)
    out = Set.new
    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file)

        out << d.irep if exclusion_reason(d, ireps, refused, conditional)
      end
    end
    out
  end

  # Why a core-source definition stays bytecode by decision (nil when eligible). One place for
  # excluded_labels and the interpreted report, so the two cannot disagree.
  def exclusion_reason(definition, ireps, refused, conditional)
    irep = ireps.fetch(definition.irep)
    return 'refused (core_refused.txt)' if refused.include?(CoreMethods.key(definition))
    return 'conditional def' if conditional.include?(definition.irep)
    return 'mruby-enumerator (Fiber machinery)' if CoreDefs.fiber_gem?(irep.file) && !enumerator_wrapper?(definition, ireps)
    return 'builds a lambda' if CoreDefs.builds_lambda?(irep, ireps)

    'names Fiber' if CoreDefs.references_fiber?(irep, ireps)
  end

  # Language features a body uses, for grouping the interpreted report by what an unsupported
  # shape needs (a method may carry several).
  def shape_tags(irep, ireps)
    ops = all_ops(irep, ireps)
    tags = []
    tags << 'block' if CoreDefs.touches_block?(irep, ireps)
    tags << 'rescue' if %w[RESCUE EXCEPT ONERR POPERR].any? { |op| ops.include?(op) }
    tags << 'super' if ops.include?('SUPER')
    tags << 'lambda' if ops.include?('LAMBDA')
    fields = irep.enter&.enter_fields&.map(&:to_i)
    tags << 'optargs' if fields && fields[1..5].any?(&:positive?)
    tags
  end

  def all_ops(irep, ireps)
    irep.reps.compact.reduce(irep.instructions.to_set(&:op)) { |acc, child| acc | all_ops(ireps.fetch(child), ireps) }
  end

  # One line per core-source bytecode definition the build keeps interpreted.
  # `unsupported` maps "Owner#name" to the compiler's own #error reason for definitions the
  # exclusion rules let through but codegen cannot express.
  def interpreted_report(defs, ireps, refused, unsupported = {})
    conditional = CoreDefs.conditional_def_labels(ireps)
    defs.filter_map do |d|
      next unless d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file)

      key = "#{d.owner}##{d.name}"
      reason = exclusion_reason(d, ireps, refused, conditional) ||
               (unsupported[key] && "unsupported shape: #{unsupported[key]}")
      next unless reason

      "#{key} | #{reason} | #{shape_tags(ireps.fetch(d.irep), ireps).join(',')}"
    end.sort
  end

  # Irep labels of the compiled core methods whose entry is guarded (CORE_BLOCK_GUARD,
  # CodeGen#core_block_guard): the ones that touch a block or are audited Enumerator wrappers.
  def guarded_labels(defs, ireps)
    defs.select { |d| d.irep && d.core && (CoreDefs.touches_block?(ireps.fetch(d.irep), ireps) || enumerator_wrapper?(d, ireps)) }.to_set(&:irep)
  end

  # Refused entries no core-source method answers to (renamed or removed).
  def stale(registry, ireps, refused)
    known = registry.values.flatten.select { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
                    .to_set { |d| CoreMethods.key(d) }
    refused.reject { |k| known.include?(k) }.sort
  end
end
