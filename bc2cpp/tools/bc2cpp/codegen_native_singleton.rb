# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'ruby_parse_cache'
require_relative 'native_singletons'

# NATIVE_SINGLETON_CALL (docs/adr/0416): `Const.name(args)` where `Const` is a class or module object the
# program cannot rebind and `name` is one C function a native source registers on that constant's singleton
# class (File.exist?, Math.sin, Time.now, Graphics.snap_to_bitmap ...).
#
# These functions read their arguments with mrb_get_args from the call frame, so unlike the RGSS entry points of
# ADR 0263 they cannot be called bare. The generated code instead runs the frame mrb_funcall would push, with
# the lookup done once per site (bc2cpp_native_singleton, symbol_cache.rb): the function, its frame, its
# argument-count checks, its backtrace entry and every error text are the interpreter's own. What the proof
# removes is the by-name lookup (two of them: the CHECKED_SEND probe and mrb_funcall's) and the
# `bc2cpp_send` dispatch site itself.
#
# The proof, all of which must hold (anything else keeps today's send):
#   1. The receiver register holds a stable class/module constant: a scoped path ConstructClassNames proves
#      (constant_object_owner, as ADR 0259), or a bare top-level native class (File, Math, Time, IO) whose
#      identity this file proves below.
#   2. At least one native registration puts `name` on `<Const>.singleton`, and every spelling of `name` in every
#      native source is a registration
#      NativeSingletons parsed (no alias, ROM entry or call by name).
#   3. No Ruby defines `name` on that singleton class, and none anywhere aliases, hides or re-scopes it (the closed
#      world's name-level facts: outside Ruby, unknown definers, visibility, dynamic installers), the closed world has no global
#      refusal (extend, define_singleton_method, ... anywhere), and the constant's singleton class has no
#      include or prepend.
#   4. The runtime fill (bc2cpp_nsc_fill) re-checks the one thing a wrong proof would break: the method found is a
#      public C function. Otherwise the site sends as before.
module NativeSingletonCall
  ENV_SWITCH = 'BC2CPP_NATIVE_SINGLETON'

  # The code for `Const.name(*argv)`, or nil when only the ordinary send is proven.
  def native_singleton_call_code(name, n, d, recv, argv, irep, idx, reg, lexical_owner, constant_owner)
    const_path, refusal = native_singleton_target(name, n, argv, irep, idx, reg, lexical_owner, constant_owner)
    warn "[NATIVE_SINGLETON_CALL] #{name}/#{n} at #{lexical_owner}: #{const_path || refusal}" if ENV['BC2CPP_NSC_DEBUG']
    return nil unless const_path

    args = argv.empty? ? '' : ", #{argv.join(', ')}"
    "  // NATIVE_SINGLETON_CALL :#{name} -> #{const_path}.singleton (stable constant, one native C registration, " \
      "nothing can precede it), method cached per site, called without lookup.\n" \
      "  r#{d} = bc2cpp_native_singleton_named(M, #{recv}, \"#{name}\", #{n}#{args});\n"
  end

  # [constant path, nil] when `Const.name` is proven to reach the one native registration, else [nil, why].
  def native_singleton_target(name, n, argv, irep, idx, reg, lexical_owner, constant_owner)
    return [nil, :disabled] if ENV[ENV_SWITCH] == '0'
    return [nil, :block] if @call_block_expr
    return [nil, :argc] if n > CodeGen::FUNCALL_ARGC_MAX || argv.size != n
    return [nil, :no_world] unless @closed_world && @native_name_sources && !symbol_installed_names.nil?
    return [nil, :installed] if devirt_blocked_name?(name) || symbol_installed_names.include?(name)
    inputs = CodeGen.native_singleton_inputs
    return [nil, :no_inputs] unless inputs

    if (why = @closed_world.native_singleton_name_refusal(name))
      return [nil, why]
    end
    return [nil, :outside_ruby] if native_singleton_foreign_names(inputs[:ruby]).include?(name)

    const_path = constant_owner || native_top_level_constant(irep, idx, reg, lexical_owner)
    return [nil, :constant] unless const_path
    return [nil, :mixin] unless native_singleton_chain_clean?(const_path)
    return [nil, :ruby_definition] if @closed_world.native_singleton_redefined?(name, "#{const_path}.singleton")
    paths = (@closed_world.native_paths + inputs[:native]).uniq
    unless NativeSingletons.unique_singleton?(name, const_path, paths)
      return [nil, "registration #{NativeSingletons.registered_owners(name, paths).inspect}"]
    end

    [const_path, nil]
  end

  # BC2CPP_NSC_DEBUG only: why `Const.name` with a proven constant did not become a CLOSED_WORLD_CONSTANT_OBJECT
  # direct call (the Ruby-defined half of the same sites).
  def constant_object_debug(name, n, lexical_owner, constant_owner)
    return unless ENV['BC2CPP_NSC_DEBUG']

    why = if devirt_blocked_name?(name) || constant_object_name_rebound?(name) then :name_rebound
          elsif !(candidate = constant_object_singleton_def(name, constant_owner)) then :no_unique_singleton_def
          elsif candidate.visibility != :public then :not_public
          elsif candidate.irep.nil? then :no_irep
          elsif !pure_mandatory_or_optional_arity?(@ireps.fetch(candidate.irep)) then :arity_shape
          elsif hot_only_excluded?(candidate.irep) then :hot_only
          elsif !constant_object_candidate_clean?(candidate.irep) then constant_object_unclean_reason(candidate.irep)
          elsif @only_owners && !@only_owners.include?(candidate.owner) && !@other_owners&.include?(candidate.owner) then :owner_not_emitted
          else :other
          end
    warn "[CONSTANT_OBJECT] #{name}/#{n} #{constant_owner} at #{lexical_owner}: #{why}"
  end

  # BC2CPP_NSC_DEBUG only: which of compiles_clean?'s answers made the candidate unclean (the symbol keeps the
  # :candidate_not_compiled_clean prefix the debug output has always had).
  def constant_object_unclean_reason(label)
    why = if self.class.core_guarded&.include?(label) then :core_guarded
          elsif resumable_method?(label) then :resumable
          elsif @probing.include?(label) then :cycle
          elsif @constant_object_probe then :nested_probe
          elsif @clean_cache[label] == false then :error_marker
          else :not_cached
          end
    :"candidate_not_compiled_clean(#{why})"
  end

  private

  # Every name the outside Ruby sources (the closed world's and the build's FOREIGN_RUBY_SRCS) define in any form.
  def native_singleton_foreign_names(paths)
    @native_singleton_foreign_names ||= foreign_method_names(paths)
  end

  # Nothing sits ahead of the constant's own singleton table: no include or prepend on it, and no mixin of
  # a name the closed world could not resolve. (An `extend` is a global refusal, already checked.)
  def native_singleton_chain_clean?(const_path)
    singleton = "#{const_path}.singleton"
    !@unknown_mixins.include?(singleton) && Array(@included_modules[singleton]).empty? &&
      Array(@prepended_modules[singleton]).empty?
  end

  # (A global refusal never reaches here: native_singleton_target asks ClosedWorld#native_singleton_name_refusal first.)
  # A bare top-level native class or module (`File`, `Math`, `Time`) the site's lexical scope cannot shadow:
  #   - the name is a StableClassConstants name (one native definition, no assignment, no const_set/
  #     remove_const anywhere) and no native source binds it under another path;
  #   - no class/module statement of the bytecode or of the outside Ruby nests a constant of that name in a
  #     scope the site can see: a lexical prefix of its owner, or any class or module on its owner's ancestor
  #     chain (the places a GETCONST searches before Object);
  #   - the register is that constant on every path to the send (agreed_constant_name).
  def native_top_level_constant(irep, idx, reg, lexical_owner)
    return nil unless irep && idx && reg && lexical_owner.is_a?(String)

    written = straight_line_constant_name(irep, idx, reg) || irep.agreed_constant_name(idx, reg.to_s)
    return nil unless written && !written.include?('::') && CodeGen.stable_class_constants&.include?(written)

    scopes = native_nested_constant_scopes(written)
    return nil unless scopes

    visible = native_constant_visible_scopes(lexical_owner.delete_suffix('.singleton'))
    return nil unless visible
    return nil if scopes.any? { |scope| visible.include?(scope) || visible.include?(scope.split('::').last) }

    written
  end

  # Every scope path ("LCF" for `module LCF; class File`) in which a class/module statement of the bytecode or
  # the outside Ruby defines +name+, or nil when one cannot be placed.
  def native_nested_constant_scopes(name)
    @native_nested_scopes ||= {}
    return @native_nested_scopes[name] if @native_nested_scopes.key?(name)

    @native_nested_scopes[name] = begin
      paths = bytecode_nested_scopes(name)
      outside = paths && NativeSingletonCall.foreign_nested_scopes((@closed_world.outside_ruby_paths + CodeGen.native_singleton_inputs[:ruby]).uniq, name)
      paths && outside && (paths | outside)
    end
  end

  def bytecode_nested_scopes(name)
    @bytecode_class_paths ||= begin
      children = @ireps.values.flat_map { |irep| irep.reps || [] }.to_set
      roots = @ireps.keys.reject { |label| children.include?(label) }
      roots.one? ? UniqueClassNames.bytecode_class_paths(@ireps, roots.first) : nil
    end
    return nil unless @bytecode_class_paths

    found = @bytecode_class_paths.fetch(name, Set.new)
    return nil if found.include?(:unknown)

    found.filter_map { |full| full.delete_suffix("::#{name}") if full != name }.to_set
  end

  # The lexical prefixes of +owner+ ("A::B::C" -> A::B::C, A::B, A) and the simple names of every class and
  # module its constant lookup can reach through ancestry; nil when a mixin cannot be named.
  def native_constant_visible_scopes(owner)
    segments = owner.split('::')
    scopes = Set.new((1..segments.size).map { |k| segments.first(k).join('::') })
    chain = unlisted_lookup_chain(owner)
    return nil unless chain

    scopes.merge(chain.select { |name| name.is_a?(String) }.map { |name| name.split('::').last })
    scopes.add('Object')
    scopes
  end

  # name => the scope paths of the class/module statements of +paths+ (Prism, so `class A::B` and nesting
  # are read as written). nil when a file does not parse.
  def self.foreign_nested_scopes(paths, name)
    @foreign_scopes ||= {}
    scopes = Set.new
    Array(paths).each do |path|
      next unless File.file?(path)

      table = (@foreign_scopes[path] ||= begin
        parsed = RubyParseCache.parse_file(path)
        return nil unless parsed.errors.empty?

        collector = ScopeCollector.new
        collector.visit(parsed.value)
        collector.table
      end)
      scopes.merge(table.fetch(name, []))
    end
    scopes
  end

  # Class/module statements: simple name => Set of the enclosing scope paths ('' removed: a top-level
  # statement reopens or defines the constant itself).
  class ScopeCollector < Prism::Visitor
    attr_reader :table

    def initialize
      super
      @stack = []
      @table = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def visit_class_node(node)
      scoped(node.constant_path) { super }
    end

    def visit_module_node(node)
      scoped(node.constant_path) { super }
    end

    private

    def scoped(path)
      text = path.slice
      absolute = text.start_with?('::')
      parts = text.delete_prefix('::').split('::')
      outer = absolute ? [] : @stack.dup
      scope = outer + parts[0...-1]
      @table[parts.last] << scope.join('::') unless scope.empty?
      pushed = absolute ? parts : parts
      saved = @stack
      @stack = absolute ? pushed : @stack + pushed
      yield
    ensure
      @stack = saved
    end
  end
end

class ClosedWorld
  # NATIVE_SINGLETON_CALL (ADR 0416): why the build's Ruby or its installers might give +name+ another body than
  # the native registration, or nil when nothing can: no definition in the registry but the native placeholder,
  # none in the outside Ruby, no unplaceable DEF, no visibility change, no global refusal.
  def native_singleton_name_refusal(name)
    return :global_refusal if @global_refusal
    return :dynamic_visibility if @dynamic_visibility
    return :unknown_def if @unknown_defs.include?(name)
    return :visibility_name if @visibility_names.include?(name)
    return :outside_ruby if @outside_ruby_names.include?(name)
    nil
  end

  # A Ruby definition of +name+ on the constant's own singleton class (`def self.x`, `class << Const`, a
  # `def Const.x`). The native function sits on that class, so it is looked up first: a definition on any
  # other owner (another class's instance method, Kernel, Class) is never reached by `Const.name`.
  def native_singleton_redefined?(name, singleton_owner)
    @registry.fetch(name, []).any? { |definition| definition.owner == singleton_owner }
  end
end

CodeGen.include(NativeSingletonCall)
