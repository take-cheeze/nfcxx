# frozen_string_literal: true

require 'set'
require_relative 'hot_methods'
require_relative 'core_defs'

# CORE_METHODS (ADR 0264): every method of mruby's own Ruby (compiled_gems.rb
# BC2CPP_CORE_MRBLIB_GEMS) that compiles clean is compiled, except the ones that
# stay bytecode by decision: a definition a later one replaces, one a
# conditional can skip, one that touches a block or the Fiber class (CoreDefs),
# and the `Owner#name` entries of core_refused.txt. An excluded definition is
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

  # BC2CPP_CORE_REFUSED=none: refuse nothing, to see what the compiler takes.
  def load_refused(path = DEFAULT_PATH)
    path == 'none' ? Set.new : HotMethods.load(path)
  end

  # Irep labels of the core-source definitions in `registry` that must not be
  # compiled: refused, conditional, block/Fiber-touching or mruby-enumerator's
  # (shadowed ones are dropped from the registry by the driver before this runs).
  def excluded_labels(registry, ireps, refused)
    conditional = CoreDefs.conditional_def_labels(ireps)
    out = Set.new
    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file)

        irep = ireps.fetch(d.irep)
        out << d.irep if refused.include?(HotMethods.key(d)) || conditional.include?(d.irep) ||
                         CoreDefs.fiber_gem?(irep.file) ||
                         CoreDefs.touches_block?(irep, ireps) || CoreDefs.references_fiber?(irep, ireps)
      end
    end
    out
  end

  # Refused entries no core-source method answers to (renamed or removed).
  def stale(registry, ireps, refused)
    known = registry.values.flatten.select { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
                    .to_set { |d| HotMethods.key(d) }
    refused.reject { |k| known.include?(k) }.sort
  end
end
