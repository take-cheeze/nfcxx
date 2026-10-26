# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'source_text'
require_relative 'scan_cache'
require_relative 'unique_class_names'

# CONST_SITE_CACHE: a GETCONST inside a namespaced owner resolves its lexical
# scope chain on every execution -- one mrb_const_get per owner path segment,
# then one probe per scope, innermost first (Game::Interpreter#execute does it
# in every `when` arm).
#
# Caching the result per site is only sound if the lookup can never resolve
# differently later. StableClassConstants proves that for a bare name that
#   (a) every `class`/`module` statement of which opens the same qualified path
#       (UniqueClassNames.bytecode_class_paths from the root irep), so no other
#       scope can define, reopen-as-something-else or shadow it: a reopening
#       statement at that path finds the one constant and defines nothing new
#       (`module LCF` in every file of mruby-lcf). Without the root irep, exactly
#       ONE statement, as before;
#   (b) is never assigned with `Name = ...` (SETCONST/SETMCNST), which is how a
#       constant gets reassigned, nor defined by a native (mrb_define_class /
#       mrb_define_const / mrb_const_set) or foreign Ruby source compiled into
#       the same VM; and
#   (c) lives in a program that never calls const_set / remove_const,
#       the other ways a constant table changes.
# (`const_get` only reads, and `const_missing` only runs on a FAILED lookup,
# which is never cached, so neither matters.) The name then denotes one class
# object for the life of the VM, and a lookup either finds it or raises
# NameError, so caching the found value is exact. When the native/foreign inputs
# are absent (a unit check building a CodeGen directly) (b) cannot be proven and
# nothing is cached.
module StableClassConstants
  DYNAMIC_MUTATION = /\b(?:const_set|remove_const)\b/

  module_function

  def analyze(ireps, native_paths, foreign_paths, root_label = nil)
    return Set.new unless native_paths && foreign_paths

    class_defs = Hash.new(0)
    assigned = Set.new
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn|
        case insn.op
        when :CLASS, :MODULE
          name = insn.sym_token
          class_defs[name] += 1 if name
        when :SETCONST
          assigned << insn.const_name
        when :SETMCNST
          assigned << insn.mcnst_name
        when :SEND, :SEND0, :SSEND, :SSEND0, :SENDB, :SSENDB, :LOADSYM
          return Set.new if insn.sym.to_s.match?(DYNAMIC_MUTATION)
        end
      end
    end
    Array(foreign_paths).each do |path|
      text = begin
        File.read(path, encoding: 'UTF-8')
      rescue SystemCallError => e
        warn "[bc2cpp] StableClassConstants: cannot read #{path}: #{e.message}"
        return Set.new
      end
      return Set.new if text.match?(DYNAMIC_MUTATION)
    end
    outside = IntegerConstants.native_defined_const_names(native_paths) |
              IntegerConstants.foreign_const_names(foreign_paths)
    paths = root_label && UniqueClassNames.bytecode_class_paths(ireps, root_label)
    one_path = ->(name, count) { paths ? paths[name].size == 1 && paths[name].first.is_a?(String) : count == 1 }
    class_defs.select { |name, count| one_path.call(name, count) && !assigned.include?(name) && !outside.include?(name) }
              .keys.to_set
  end
end

# CONST_VALUE_CACHE: the same cache for a bare name whose one binding is not a
# class/module, e.g. optcarrot's Integer `CLK_3` (bound by a `map` masgn, so no
# literal folds it) and FOREVER_CLOCK = 0xffffffff, too large for a Fixnum fold.
# Every read paid the whole scope-chain lookup. Soundness is the class proof's,
# with "not a class" standing in for "is a class": exactly one SETCONST/SETMCNST of
# the bare name in the program, no CLASS/MODULE of it, no native or foreign
# definition, no const_set/remove_const. The one binding is then fixed for the
# life of the VM, and a failed lookup raises before anything is stored.
module StableValueConstants
  module_function

  def analyze(ireps, native_paths, foreign_paths)
    return Set.new unless native_paths && foreign_paths

    bindings = Hash.new(0)
    class_defs = Hash.new(0)
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn|
        case insn.op
        when :CLASS, :MODULE
          name = insn.sym_token
          class_defs[name] += 1 if name
        when :SETCONST
          bindings[insn.const_name] += 1
        when :SETMCNST
          bindings[insn.mcnst_name] += 1
        when :SEND, :SEND0, :SSEND, :SSEND0, :SENDB, :SSENDB, :LOADSYM
          return Set.new if insn.sym.to_s.match?(StableClassConstants::DYNAMIC_MUTATION)
        end
      end
    end
    Array(foreign_paths).each do |path|
      text = begin
        File.read(path, encoding: 'UTF-8')
      rescue SystemCallError => e
        warn "[bc2cpp] StableValueConstants: cannot read #{path}: #{e.message}"
        return Set.new
      end
      return Set.new if text.match?(StableClassConstants::DYNAMIC_MUTATION)
    end
    outside = IntegerConstants.native_defined_const_names(native_paths) |
              IntegerConstants.foreign_const_names(foreign_paths)
    bindings.select { |name, count| count == 1 && class_defs[name].zero? && !outside.include?(name) }.keys.to_set
  end
end

# NATIVE_CLASS_CONSTANT_CACHE: the same cache for bare names a native
# `mrb_define_class`/`_module` defines (Symbol, Array, ... and every native
# gem's classes), which leave no CLASS/MODULE bytecode for `analyze` to see --
# e.g. `LCF::Array1D#[]`'s `idx.is_a? Symbol`. The names come from the real
# native sources, never a hand-written builtin list. Kept separate from
# `analyze` (whose claim is "exactly one Ruby class/module statement"); the
# caller unions the two.
#
# Soundness:
# 1. A native definition runs once per VM, at gem init, before any compiled
#    code (the same trust the owner-class cache already rests on). A bare name
#    defined by more than one distinct native site is refused.
# 2. After that, the constant can only be rebound by SETCONST/SETMCNST,
#    const_set or remove_const (3rd/mruby/src/variable.c) -- the
#    same bare-name-keyed poisoning StableClassConstants already applies.
# 3. A Ruby `class Symbol` reopening (closed world or foreign, e.g.
#    3rd/mruby/mrblib/symbol.rb) reuses the existing class via OP_CLASS and
#    never rebinds the constant, so only a foreign plain assignment
#    disqualifies a name here (foreign_reassigned_names).
# 4. A same-named class nested elsewhere is harmless: emit_const_site_cache
#    keys each helper by [owner_path, name] and still runs that site's full
#    lexical lookup on first call; only the reuse of that result is proven.
module StableClassConstants
  # The call shapes NativeExpressionDevirt.analyze_exact_class_expressions
  # recognizes (`mrb_define_(class|module)_id(mrb, MRB_SYM(Name), ...)`,
  # `mrb_define_(class|module)(_under)?(mrb, "Name", ...)`, class.c's
  # `boot_defclass`+`mrb_define_const_id`), reduced to the bare names.
  def self.native_class_module_names(native_paths)
    ScanCache.fetch('stable_class_constants.native_class_module_names', Array(native_paths), cache_absent: true) do
      counts = Hash.new(0)
      Array(native_paths).each do |path|
        next unless File.file?(path)

        source = File.read(path, encoding: 'UTF-8')
        source.scan(/\bmrb_define_(?:class|module)_id\s*\(\s*\w+\s*,\s*MRB_SYM\((\w+)\)/) { counts[Regexp.last_match(1)] += 1 }
        source.scan(/\bmrb_define_(?:class|module)(?:_under)?\s*\(\s*\w+(?:\s*,\s*\w+)?\s*,\s*"([^"]+)"/) do
          counts[Regexp.last_match(1)] += 1
        end
        booted = source.include?('boot_defclass') ? source.scan(/(?<!\w)(\w+)\s*=\s*boot_defclass\s*\(/).flatten : []
        next if booted.empty?

        source.scan(/mrb_define_const_id\s*\(\s*\w+\s*,\s*(\w+)\s*,\s*MRB_SYM\((\w+)\)\s*,\s*mrb_obj_value\(\1\)\s*\)/) do |variable, name|
          counts[name] += 1 if booted.include?(variable)
        end
      end
      # Refuse a bare name defined by more than one distinct native site.
      counts.select { |_name, count| count == 1 }.keys.to_set
    end
  end

  # Only the `Name = value` half of `IntegerConstants.foreign_const_names`: its
  # `class`/`module` half also matches a harmless reopening (point 3 above).
  def self.foreign_reassigned_names(paths)
    ScanCache.fetch('stable_class_constants.foreign_reassigned_names', Array(paths), cache_absent: false) do
      names = Set.new
      Array(paths).each do |path|
        text = SourceText.read(path, 'StableClassConstants.foreign_reassigned_names') or next
        text.scan(/^\s*([A-Z][A-Za-z_0-9]*)\s*=[^=~]/) { names << Regexp.last_match(1) }
      end
      names
    end
  end

  # The native sibling of `analyze`; the caller unions the two Sets. Both require
  # the same non-reassignment preconditions, so an overlap is only redundant.
  def self.analyze_native(ireps, native_paths, foreign_paths)
    return Set.new unless native_paths && foreign_paths

    assigned = Set.new
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn|
        case insn.op
        when :SETCONST
          assigned << insn.const_name
        when :SETMCNST
          assigned << insn.mcnst_name
        when :SEND, :SEND0, :SSEND, :SSEND0, :SENDB, :SSENDB, :LOADSYM
          return Set.new if insn.sym.to_s.match?(DYNAMIC_MUTATION)
        end
      end
    end
    Array(foreign_paths).each do |path|
      text = begin
        File.read(path, encoding: 'UTF-8')
      rescue SystemCallError => e
        warn "[bc2cpp] StableClassConstants: cannot read #{path}: #{e.message}"
        return Set.new
      end
      return Set.new if text.match?(DYNAMIC_MUTATION)
    end
    foreign_reassigned = foreign_reassigned_names(foreign_paths)
    native_class_module_names(native_paths).reject { |name| assigned.include?(name) || foreign_reassigned.include?(name) }.to_set
  end
end
