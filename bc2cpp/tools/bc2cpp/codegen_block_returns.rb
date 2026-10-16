# frozen_string_literal: true

require 'tmpdir'
require_relative 'block_returns'
require_relative 'codegen_return_classes'
require_relative 'foreign_definers'
require_relative 'numeric_flow'

module BlockReturns
  # A literal block's own flow: captures, constants, ivars and arguments are unknown, so its result never rests on
  # a fact of the flow being computed around it.
  class Oracle < CodeGen::ExactOracle
    def entry_mask(_irep, _reg) = NumericFlow::OTHER
    def const_mask(_insn) = NumericFlow::OTHER
    def ivar_entry_mask(_irep, _name) = NumericFlow::OTHER
    def ivar_fact_mask(_irep, _name) = NumericFlow::OTHER
    def upvar_mask(_irep, _insn) = NumericFlow::OTHER
  end

  # One Ruby definition a block-return check reads: its owner, its body and the irep table its nested blocks are in
  # (an outside Ruby source compiled for the check has its own), and where it comes from.
  RubyDef = Struct.new(:owner, :irep, :ireps, :source, keyword_init: true)
end

# CodeGen: BLOCK_RETURNS (docs/adr/0475), the use of the declarations block_returns.rb reads and checks.
#
# A call site `recv.m(args) { ... }` (SENDB/SSENDB, plain fixed argc, the block a dominating literal BLOCK) gets the
# declaration's result when every method the call can run is a checked declaration of the same shape:
#   * a native singleton declaration (`def self.m` in sig/native) on a module or class constant C: the receiver is
#     the constant C (straight-line constant path, lexically resolved), C and its enclosing constants keep their
#     identity, one native source spells the name and it is the scanned one, no Ruby definition sits on C or its
#     singleton, no prepend or unresolved mixin on either, and no installer, alias or opaque core definition can
#     rename or replace it (the conditions PROFILER_RESULTS used for RGSS::Profiler, ADR 0344);
#   * otherwise by name: every bytecode definition of the name anywhere (program, mruby's own Ruby, outside Ruby
#     sources, aliases included) is a checked declaration of one shape, no native registers it, nothing installs,
#     aliases, undefines or method_missing-answers it.
# The block must not `break` or `return` (core_ruby_result_exits_safe?): either would replace the call's value.
#
# What the site then knows:
#   :block_value  the call's class set is the join of the block's returns (BlockReturns::Oracle flow), joined into
#                 RETURN_CLASS_TABLE (block_send_mask) and read by RBS_CHECKED_PARAMS (rbs_param_check.rb);
#   :self         the call's class set is the receiver's;
#   both          the block runs under the caller's self (BLOCK_SELF, codegen_block_self.rb).
class CodeGen
  class << self
    # [BlockReturns::Entry] of this build's signatures (nil: none).
    attr_accessor :block_returns
  end

  def block_return_entries
    @block_return_entries ||= (self.class.block_returns || []).reject(&:problem)
  end

  def block_return_entries_by_name
    @block_return_entries_by_name ||= block_return_entries.group_by(&:name)
  end

  def block_return_entry(owner, name)
    block_return_entries_by_name.fetch(name, []).find { |entry| entry.owner == owner }
  end

  # -------------------------------------------------------------------------------------------- checking

  # nil when +entry+ is verified, else [severity, why]: 'error' for a declaration a body contradicts or a native
  # that is neither verified nor reviewed, 'info' for one this build has no definition of (no fact).
  def block_return_entry_why(entry)
    @block_return_entry_why ||= {}
    return @block_return_entry_why[entry.key] if @block_return_entry_why.key?(entry.key)

    @block_return_entry_why[entry.key] = compute_block_return_entry_why(entry)
  end

  def compute_block_return_entry_why(entry)
    defs, failed = block_return_ruby_defs(entry.name)
    failed.each do |path, why|
      return ['error', "cannot be checked: #{why}"] if ForeignDefiners.defines?([path], entry.owner, entry.name)
    end

    mine = defs.select { |d| d.owner == entry.owner }
    unless mine.empty?
      mine.each do |d|
        body_why = BlockReturns.ruby_body_why(d.irep, d.ireps, entry)
        return ['error', "#{d.owner}##{entry.name} (#{d.source}) #{body_why}"] if body_why
      end
      return nil
    end
    unless entry.native
      return ['error', "#{entry.owner}##{entry.name} has no Ruby definition; a native method is declared in sig/native"]
    end

    native_why, found = BlockReturns.native_entry_why(entry, block_return_native_paths(entry.name))
    return ['error', native_why] if native_why
    return ['info', "nothing in this build defines #{entry.owner}##{entry.name}; no fact"] if found.zero?

    nil
  end

  def block_return_native_paths(name)
    paths = Array(@closed_world&.native_paths_spelling(name)) + Array(@native_name_sources&.fetch(name, nil))
    paths.map { |path| File.expand_path(path) }.uniq.select { |path| File.file?(path) }
  end

  # [[BlockReturns::RubyDef], {path => why}]: every bytecode definition of +name+ (aliases included), and the outside
  # Ruby sources that spell the name but do not compile on their own.
  def block_return_ruby_defs(name)
    @block_return_ruby_defs ||= {}
    @block_return_ruby_defs[name] ||= compute_block_return_ruby_defs(name)
  end

  def compute_block_return_ruby_defs(name)
    bodies = self.class.block_self_bodies || {}
    compiled = ((@registry[name] || []) + (bodies[name] || [])).select(&:irep).uniq { |d| [d.owner, d.irep] }
    defs = compiled.map { |d| BlockReturns::RubyDef.new(owner: d.owner, irep: @ireps[d.irep], ireps: @ireps, source: 'compiled') }
    files = @ireps.each_value.to_set { |irep| File.expand_path(irep.file.to_s) }
    failed = {}
    return [defs, failed] unless @closed_world

    @closed_world.outside_ruby_paths_defining(name).each do |path|
      next if files.include?(File.expand_path(path))

      world, why = block_return_foreign_world(path)
      why ? failed[path] = why : defs.concat(world.fetch(name, []))
    end
    [defs, failed]
  end

  # name => [BlockReturns::RubyDef] of one outside Ruby source compiled on its own, or [nil, why]. An alias is the
  # aliased body under the new name, when the alias runs unconditionally in a class or module body of that file.
  def block_return_foreign_world(path)
    @block_return_foreign_worlds ||= {}
    @block_return_foreign_worlds[path] ||= begin
      Dir.mktmpdir('bc2cpp-block-returns') do |dir|
        ireps, root = compile_ireps([path], 'bc2cpp_block_returns', dir)
        registry, *, alias_sites = build_registry(ireps, root)
        out = Hash.new { |h, k| h[k] = [] }
        registry.each_value do |defs|
          defs.each do |d|
            next unless d.irep

            out[d.name] << BlockReturns::RubyDef.new(owner: d.owner, irep: ireps[d.irep], ireps: ireps, source: path)
          end
        end
        alias_sites.each do |site|
          body = ireps[site[:irep]]
          next unless body && body.instructions.none? { |insn| insn.branch_target }

          out[site[:old]].select { |d| d.owner == site[:owner] }.each do |d|
            out[site[:new]] << BlockReturns::RubyDef.new(owner: d.owner, irep: d.irep, ireps: ireps, source: "#{path} (alias)")
          end
        end
        [out, nil]
      end
    rescue StandardError => e
      [nil, "#{path} does not compile on its own (#{e.class}: #{e.message.lines.first&.strip})"]
    end
  end

  # Runs with DECLARED_RETURN_CHECK (codegen_declared_returns.rb): its report and its abort carry these diagnostics.
  def check_block_returns
    (self.class.block_returns || []).each do |entry|
      loc = entry.loc
      if entry.problem
        @declared_return_diagnostics << declared_return_diag(loc.file, loc.line, loc.col, 'info',
                                                             "#{entry.key}: #{entry.problem}; not a checked block return")
        @declared_return_report << "  BLOCK_RET #{entry.key} #{entry.text}: not checked (#{entry.problem})"
        next
      end
      severity, why = block_return_entry_why(entry)
      @declared_return_diagnostics << declared_return_diag(loc.file, loc.line, loc.col, severity, "#{entry.key}: #{why}") if why
      status = if why.nil? then "checked, #{entry.kind}"
               elsif severity == 'info' then 'no definition, no fact'
               else 'FAILED'
               end
      @declared_return_report << "  BLOCK_RET #{entry.key} #{entry.text}: #{status}"
    end
  end

  # ----------------------------------------------------------------------------------------------- call sites

  # [entry, literal block irep] when the block send at +index+ runs only checked declarations of one shape.
  def block_return_site(irep, index, insn)
    return nil unless %w[SENDB SSENDB].include?(insn.op) && insn.plain_fixed_argc?
    return nil if block_return_entries.empty? || !block_return_entries_by_name.key?(insn.sym)

    @block_return_sites ||= {}
    key = [irep.label, index]
    return @block_return_sites[key] if @block_return_sites.key?(key)

    @block_return_sites[key] = compute_block_return_site(irep, index, insn)
  end

  def compute_block_return_site(irep, index, insn)
    return nil unless @closed_world&.exact_instances_singleton_free? && captured_local_class_enabled?

    reg = (insn.reg.to_i + insn.argc + 1).to_s
    body = irep.walk_dominating_writers(index - 1, reg, follow_moves: true) do |writer|
      @ireps[irep.reps[writer.block_index]] if writer.op == 'BLOCK'
    end
    return nil unless body && core_ruby_result_exits_safe?(body)

    entry = block_return_native_site_entry(irep, index, insn) || block_return_name_entry(insn.sym)
    return nil unless entry && entry.args == insn.argc
    return nil if entry.kind == :self && insn.op != 'SENDB'

    [entry, body]
  end

  # The native singleton declaration the call reaches through its constant receiver, or nil.
  def block_return_native_site_entry(irep, index, insn)
    return nil unless insn.op == 'SENDB'

    block_return_entries_by_name.fetch(insn.sym, []).find do |entry|
      next false unless entry.native && entry.owner.end_with?('.singleton')

      const = entry.owner.delete_suffix('.singleton')
      top = const.split('::').first
      block_return_native_lookup_safe?(entry) &&
        straight_line_constant_name(irep, index, insn.reg, skip_blocks: true) == const &&
        resolve_class_constant_name(top, numeric_owner_of(irep)&.owner) == top
    end
  end

  # The closed-world half of a native singleton declaration's site fact (see the class comment).
  def block_return_native_lookup_safe?(entry)
    @block_return_native_lookup ||= {}
    return @block_return_native_lookup[entry.key] if @block_return_native_lookup.key?(entry.key)

    @block_return_native_lookup[entry.key] = compute_block_return_native_lookup_safe?(entry)
  end

  def compute_block_return_native_lookup_safe?(entry)
    return false unless @closed_world && block_return_entry_why(entry).nil?

    name = entry.name
    const = entry.owner.delete_suffix('.singleton')
    simple = const.split('::').last
    paths = block_return_native_paths(name)
    return false unless paths.one?

    path = paths.first
    fragment = "/#{File.basename(File.dirname(File.dirname(path)))}/#{File.basename(File.dirname(path))}/"
    source = File.binread(path).force_encoding(Encoding::BINARY)
    # Every binding of the constant is this source's own definition of the module or class.
    bindings = BlockReturns.strip_comments(source).scan(/\bmrb_define_(?:module|class)(?:_under)?(?:_id)?\s*\([^;]*?"#{Regexp.escape(simple)}"/).size
    installed = symbol_installed_names
    core_installed = self.class.core_result_installed_names
    opaque = self.class.core_result_opaque_defs
    scopes = const.split('::').each_index.map { |i| const.split('::')[0..i].join('::') }[0...-1]
    bindings.positive? && @closed_world.native_exact_direct_name_safe?(name, fragment) &&
      @closed_world.native_class_constant_stable?(const, bindings: bindings) &&
      scopes.all? { |scope| @closed_world.stable_constant_identity?(scope) } &&
      installed && !installed.include?(name) && core_installed && !core_installed.include?(name) &&
      opaque && opaque.none? { |_owner, method| method == name } &&
      !devirt_blocked_name?(name) && !numeric_aliased_names.include?(name) &&
      (@registry[name] || []).none? { |d| d.owner.delete_suffix('.singleton').split('::').last == simple } &&
      [const, "#{const}.singleton"].all? do |owner|
        Array(@prepended_modules[owner]).empty? && !@unknown_mixins.include?(owner)
      end
  end

  # The one shape every definition of +name+ is checked to have, when a call by name can only run those; else nil.
  def block_return_name_entry(name)
    @block_return_name_entry ||= {}
    return @block_return_name_entry[name] if @block_return_name_entry.key?(name)

    @block_return_name_entry[name] = compute_block_return_name_entry(name)
  end

  def compute_block_return_name_entry(name)
    return nil unless @closed_world && @closed_world.global_refusal.nil? && !@closed_world.unknown_def?(name)
    return nil unless block_return_native_paths(name).empty?

    installed = symbol_installed_names
    core_installed = self.class.core_result_installed_names
    return nil unless installed && !installed.include?(name) && core_installed && !core_installed.include?(name)
    return nil if numeric_aliased_names.include?(name)
    return nil unless block_return_method_missing_native?

    defs, failed = block_return_ruby_defs(name)
    return nil unless failed.empty? && !defs.empty?
    return nil if ((@registry[name] || []) + (self.class.block_self_bodies&.[](name) || [])).any? { |d| d.irep.nil? }

    entries = defs.map { |d| block_return_entry(d.owner, name) }
    return nil unless entries.all? { |entry| entry && block_return_entry_why(entry).nil? }
    return nil unless entries.map { |entry| [entry.kind, entry.args, entry.arity] }.uniq.one?

    entries.first
  end

  # A receiver without the method runs method_missing with the block: only mruby's native one (NoMethodError).
  def block_return_method_missing_native?
    return @block_return_method_missing_native if defined?(@block_return_method_missing_native)

    defs = (@registry['method_missing'] || []) + (self.class.block_self_bodies&.[]('method_missing') || [])
    @block_return_method_missing_native = defs.all? { |d| d.owner == '<native>' && d.irep.nil? } &&
                                          @closed_world.outside_ruby_paths_defining('method_missing').empty? &&
                                          !@closed_world.unknown_def?('method_missing')
  end

  # A nested callee's changing result must invalidate every enclosing result.
  def setup_block_return_dependencies
    @block_return_parents = Hash.new { |h, k| h[k] = Set.new }
    return if block_return_entries.empty?

    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, index|
        entry, body = block_return_site(irep, index, insn)
        next unless entry&.kind == :block_value

        stack = [body.label]
        until stack.empty?
          label = stack.pop
          next unless @block_return_parents[label].add?(irep.label)

          stack.concat(@ireps.fetch(label).reps)
        end
      end
    end
  end

  # The class mask of a block send whose declaration is checked (RETURN_CLASS_TABLE's block_send_mask), or nil.
  def block_return_class_result(irep, index, insn, state)
    entry, body = block_return_site(irep, index, insn)
    return nil unless entry
    if entry.kind == :self
      receiver = state[insn.reg.to_i]
      return receiver.is_a?(Integer) && (receiver & NumericFlow::OTHER).zero? ? receiver : nil
    end

    states = NumericFlow.states(body, BlockReturns::Oracle.new(self), fixnum_proof_ctx(body)[:upvars])
    return nil unless states

    mask = body.instructions.each_with_index.reduce(0) do |joined, (op, idx)|
      s = states[idx]
      value = if s && op.op == 'RETURN' then s[op.reg.to_i]
              elsif s && op.op == 'RETNIL' then NumericFlow::NIL
              elsif s && %w[RETSELF RETTRUE RETFALSE STOP].include?(op.op) then NumericFlow::OTHER
              else 0
              end
      joined | value
    end
    mask if (mask & NumericFlow::OTHER).zero?
  end
end
