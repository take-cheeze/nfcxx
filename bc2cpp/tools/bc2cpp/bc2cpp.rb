#!/usr/bin/env ruby
# frozen_string_literal: true

# A small mruby bytecode -> C++ AOT compiler (docs/adr/0139).
#
# Compiles method-body IREPs only; top-level and class-body IREPs stay on the
# interpreter (mrb_load_irep), which defines the classes and installs the
# compiled bodies via mrb_define_method. A method using an unsupported opcode
# or argument shape gets a loud `#error` marker, never a silently wrong
# translation, and keeps running interpreted.
#
# The core analysis is closed-world: a method name defined by exactly one class
# anywhere in the program is provably monomorphic, so its call sites compile to
# a direct C++ call instead of mrb_funcall; names with several definitions keep
# dynamic dispatch.
#
# Input is mrbc's RITE binary (`-g`): irep.rb builds every Irep (tree, pool,
# symbols, lv, instructions) from it, see ADR 0249 and ADR 0251.

require 'shellwords'
require 'set'

# Parts split out by scripts/bc2cpp_split.rb, loaded in original definition order.
require_relative 'irep'
require_relative 'bytecode_ir'
require_relative 'registry'
require_relative 'lint_crosscheck'
require_relative 'native_names'
require_relative 'native_ivar_scopes'

require_relative 'native_expression_devirt'
require_relative 'symbol_cache'
require_relative 'const_site_cache'
require_relative 'static_dispatch_unregistered'
require_relative 'unique_class_names'
require_relative 'construct_class_names'
require_relative 'annotation_contradictions'
require_relative 'class_arg_types'
require_relative 'closed_world'
require_relative 'nomethod_reviewed'
require_relative 'proven_miss_reviewed'
require_relative 'hot_methods'
require_relative 'core_methods'

require_relative 'integer_constants'
require_relative 'integer_constant_ranges'
require_relative 'native_construct_schema'
require_relative 'dynamic_names'
require_relative 'ivar_layout'
require_relative 'annotations'
require_relative 'class_layout'
require_relative 'element_layouts'
require_relative 'record_hash'
require_relative 'diagnostics'
require_relative 'dispatch_targets'
require_relative 'irep_arity'
require_relative 'codegen'
require_relative 'codegen_ivar_poly'
require_relative 'codegen_native_send'
require_relative 'codegen_exact_receiver'
require_relative 'codegen_native_direct'
require_relative 'codegen_native_exact_direct'
require_relative 'codegen_exact_native_wrappers'
require_relative 'codegen_native_core_direct'
require_relative 'codegen_numeric_native_direct'
require_relative 'codegen_core_methods'
require_relative 'core_compare'
require_relative 'codegen_receiver_facts'
require_relative 'codegen_record_hash'
require_relative 'codegen_lcf_rows'
require_relative 'codegen_frozen_tables'
require_relative 'codegen_emit'
require_relative 'codegen_method'
require_relative 'codegen_rescue'
require_relative 'codegen_loop_regions'
require_relative 'codegen_fixnum_proof'
require_relative 'codegen_numeric_proof'
require_relative 'codegen_numeric_args'
require_relative 'codegen_numeric_ivars'
require_relative 'codegen_numeric_returns'
require_relative 'codegen_class_pools'
require_relative 'codegen_constructor_pools'
require_relative 'codegen_return_classes'
require_relative 'codegen_profiler_results'
require_relative 'codegen_core_ruby_results'
require_relative 'codegen_return_accessors'
require_relative 'codegen_exact_core_arms'
require_relative 'codegen_captured_locals'
require_relative 'codegen_native_results'
require_relative 'codegen_instance_receivers'
require_relative 'codegen_class_narrowing'
require_relative 'codegen_call_facts'
require_relative 'codegen_nilable_receiver'
require_relative 'codegen_setter_pools'
require_relative 'codegen_checked_send'
require_relative 'codegen_numeric_consts'
require_relative 'codegen_numeric_slow'
require_relative 'codegen_numeric_slow_misc'
require_relative 'codegen_numeric_slow_zero'
require_relative 'codegen_index_closed'
require_relative 'codegen_collection_ops'
require_relative 'codegen_numeric_roots'
require_relative 'codegen_native_int_args'
require_relative 'codegen_native_param_unbox'
require_relative 'codegen_fixnum_ranges'
require_relative 'codegen_tuple_returns'
require_relative 'codegen_return_analysis'
require_relative 'codegen_loop_inline'
require_relative 'codegen_step_loop'
require_relative 'codegen_resumable'
require_relative 'codegen_block_fallback'
require_relative 'codegen_yield_free'
require_relative 'codegen_runtime_def'
require_relative 'codegen_insn'
require_relative 'codegen_keyword_send'
require_relative 'codegen_send'
require_relative 'codegen_eqq'
require_relative 'codegen_constant_object'
require_relative 'codegen_unlisted_class_call'
require_relative 'codegen_arg_shapes'
require_relative 'codegen_computed_send'
require_relative 'codegen_block_core_direct'
require_relative 'codegen_core_exact_direct'
require_relative 'codegen_core_compiled_cmp'
require_relative 'codegen_interface_tables'
require_relative 'codegen_block_param_call'
require_relative 'escape_analysis'
require_relative 'codegen_escape'
require_relative 'escape_report' if ENV['BC2CPP_ESCAPE_REPORT']
require_relative 'cha_self_report' if ENV['BC2CPP_CHA_REPORT']
require_relative 'guard_hint_report' if ENV['BC2CPP_GUARD_HINT_REPORT']
require_relative 'interface_table_report' if ENV['BC2CPP_ITAB_REPORT']
require_relative 'send_root_report' if ENV['BC2CPP_SEND_ROOT_REPORT'] || ENV['BC2CPP_POOL_DROP_REPORT']
require_relative 'site_origin_table' if ENV['BC2CPP_SITE_ORIGIN_TABLE']
require_relative 'refine_report' if ENV['BC2CPP_REFINE_REPORT']
require_relative 'native_arms_report' if ENV['BC2CPP_NATIVE_ARMS_REPORT']
require_relative 'block_send_report' if ENV['BC2CPP_BLOCK_SEND_REPORT']
require_relative 'provable_error_report' if ENV['BC2CPP_PROVABLE_ERROR_REPORT']
require_relative 'dead_arm_report' if ENV['BC2CPP_DEAD_ARM_REPORT']
require_relative 'element_site_report' if ENV['BC2CPP_ELEMENT_REPORT']
require_relative 'receiver_proof_report' if ENV['BC2CPP_RECEIVER_PROOF_REPORT']
require_relative 'native_setter_report' if ENV['BC2CPP_NATIVE_SETTER_REPORT']

if $PROGRAM_NAME == __FILE__
  srcs = ARGV
  raise 'usage: bc2cpp.rb file1.rb [file2.rb ...]  (env: MRBC, OUT_SYMBOL, OUT_DIR, ONLY_OWNERS)' if srcs.empty?

  symbol = ENV['OUT_SYMBOL'] || File.basename(srcs.first, '.rb').gsub(/[^a-zA-Z0-9_]/, '_')
  out_dir = ENV['OUT_DIR'] || File.dirname(srcs.first)
  profile_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  profile_last = profile_started
  profile_phase = lambda do |name|
    next unless ENV['BC2CPP_PROFILE_TIMINGS'] == '1'

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    warn format('BC2CPP_TIME %-32s %8.3fs (total %8.3fs)', name, now - profile_last, now - profile_started)
    profile_last = now
  end
  profile_call = lambda do |name, &block|
    next block.call unless ENV['BC2CPP_PROFILE_TIMINGS'] == '1'

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = block.call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    warn format('BC2CPP_DETAIL %-40s %8.3fs', name, elapsed)
    value
  end

  ireps, root_label = compile_ireps(srcs, symbol, out_dir)
  order = dfs_order(ireps, root_label)
  registry, superclass_of, container_constants, included_modules, prepended_modules, unknown_mixins,
    struct_member_lists, class_decls, walked_ireps, module_body_ivar_labels, constant_assignment_sites,
    declared_modules, alias_sites = build_registry(ireps, root_label)
  # ESCAPE_ANALYSIS (ADR 0316): callees are every definition of a name, so the registry is copied before
  # the core filtering below drops the methods the build keeps interpreted.
  escape_registry = EscapeAnalysis.enabled? ? registry.transform_values(&:dup) : nil
  # CORE_DEFS (ADR 0264): a core-source definition a later one replaces is not the
  # method the interpreter ends up with, so it must not make the name POLY nor be
  # emitted. Dropped before anything reads the registry.
  CodeGen.module_names = declared_modules
  core_shadowed = CoreDefs.shadowed_labels(registry, ireps)
  core_shadowed_pairs = registry.values.flatten.select { |d| d.irep && core_shadowed.include?(d.irep) }
                                .to_set { |d| [d.owner, d.name] }
  registry.each_value { |defs| defs.reject! { |d| d.irep && core_shadowed.include?(d.irep) } }
  registry.each_value do |defs|
    defs.each { |d| d.core = true if d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
  end
  CodeGen.core_aliases = CoreDefs.alias_map(alias_sites, registry, ireps, core_shadowed_pairs)
  # CORE_METHODS: what mruby's own Ruby must keep interpreted is no registry definition either.
  core_refused = CoreMethods.load_refused(ENV['BC2CPP_CORE_REFUSED'] || CoreMethods::DEFAULT_PATH)
  core_ineligible = CoreMethods.excluded_labels(registry, ireps, core_refused)
  # ADR 0338: an interpreted core replacement still intercepts inherited lookup.
  CodeGen.core_result_opaque_defs = CoreRubyResults.opaque_definitions(registry, core_ineligible, ireps, alias_sites, CodeGen.core_aliases)
  CodeGen.core_result_installed_names = CoreRubyResults.installed_names(ireps)
  core_stale_refusals = CoreMethods.stale(registry, ireps, core_refused)
  core_bytecode = registry.values.flatten.count { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
  core_all_defs = registry.values.flatten.select { |d| d.irep && d.core }
  # A core attr_* accessor or module_function copy has no body to compile: it stays the interpreter's.
  registry.each_value { |defs| defs.reject! { |d| d.irep ? core_ineligible.include?(d.irep) : d.core } }
  registry.delete_if { |_, defs| defs.empty? }
  profile_phase.call('mrbc + parse + registry')

  # CLOSED_WORLD (docs/adr/0210): construct this before return/element
  # analysis, which uses its method-lookup proof for inherited return classes.
  closed_world = nil
  if ENV['BC2CPP_CLOSED_WORLD'] == '1'
    repo_root = File.expand_path('../..', __dir__)
    build_name = ENV['BC2CPP_BUILD_NAME'].to_s
    build_gems = Shellwords.split(ENV['BC2CPP_BUILD_GEMS'].to_s).to_h { |kv| kv.split('=', 2) }
    CodeGen.build_gem_names = build_gems.keys.to_set
    errors = bc2cpp_closed_world_violations(build_name, build_gems, repo_root)
    abort "bc2cpp: BC2CPP_CLOSED_WORLD refused for build '#{build_name}':\n  #{errors.join("\n  ")}" unless errors.empty?

    outside_native, outside_ruby = bc2cpp_closed_world_outside_srcs(build_name, build_gems, repo_root)
    # Core Ruby is compiled input here but stays an OUTSIDE source for these proofs: the
    # closed world is the engine's own Ruby, and a name mruby's own Ruby defines is one
    # the engine's proofs cannot enumerate (core_or_native), exactly as before.
    engine_ireps = ireps.reject { |label, irep| label != root_label && CoreDefs.core_source?(irep.file) }
    engine_registry = registry.transform_values { |defs| defs.reject(&:core) }.reject { |_, defs| defs.empty? }
    closed_world = ClosedWorld.new(ireps: engine_ireps, registry: engine_registry, class_decls: class_decls,
                                   walked: walked_ireps & engine_ireps.keys,
                                   native_paths: outside_native, ruby_paths: outside_ruby,
                                   module_names: declared_modules)
    warn "== closed world (#{build_name}: #{build_gems.size} gems, #{outside_native.size} native + " \
         "#{outside_ruby.size} Ruby outside sources) =="
    warn "  global refusal: #{closed_world.global_refusal || 'none'}"
    warn "  method_missing classes: #{closed_world.method_missing_classes.to_a.sort.join(', ')}"
    warn ''
    LintCrosscheck.enforce!(repo_root, closed_world)
  end

  # DEFINE_METHOD_SITES (ADR 0288): the class-body `define_method(:x) { }` candidates the registry
  # collected stay definitions only in a closed world that trusts `define_method` itself.
  define_method_kept, define_method_dropped =
    DefineMethodSites.settle(registry, trusted: closed_world&.define_method_sites_trusted? || false)
  if define_method_kept + define_method_dropped > 0
    warn "== define_method sites (#{define_method_kept} registered as definitions, " \
         "#{define_method_dropped} left as installers) =="
  end

  # NATIVE_SRCS: C/C++ sources to scan for mrb_define_method-family calls (see
  # extract_native_method_names). Without it the registry cannot see native
  # definitions.
  native_name_sources = nil
  native_names = Set.new
  native_expression_devirt = {}
  native_registered_expressions = {}
  if ENV['NATIVE_SRCS']
    native_paths = Shellwords.split(ENV['NATIVE_SRCS'])
    native_expression_devirt = NativeExpressionDevirt.analyze(native_paths)
    native_registered_expressions = NativeExpressionDevirt.analyze_exact_class_expressions(native_paths)
    warn "== generated native C-expression devirtualizations (#{native_expression_devirt.size}) =="
    native_expression_devirt.sort.each { |name, expression| warn "  C_EXPR :#{name}  (#{expression})" }
    native_registered_expressions.sort.each do |name, entries|
      entries.each do |entry|
        owner = entry[:owner]
        warn "  C_EXPR :#{name}  (#{owner[:class_name]}##{name}: #{entry[:expression]})"
      end
    end
    warn ''
    # ZSUPER_NATIVE_SUPPORT: the flat name set is derived from the per-name source
    # map, so NATIVE_SRCS is read once and the two agree.
    native_name_sources = extract_native_method_sources(native_paths)
    native_names = native_name_sources.keys.to_set
    flipped = native_names.select { |n| registry.key?(n) && registry[n].size == 1 }
    native_names.each do |name|
      registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public)
    end
    warn "== native method names (#{native_names.size} from NATIVE_SRCS, #{flipped.size} flipped a MONO name to POLY) =="
    flipped.sort.each { |n| warn "  FLIP :#{n}" }
    warn ''
    # NATIVE_CONSTRUCT_SCHEMA_AUDIT: audit only; skipped without NATIVE_SRCS.
    warn '== native construct schema audit (row vs scraped mrb_get_args) =='
    NATIVE_CONSTRUCT_TARGETS.sort.each do |klass, row|
      verdict, detail = NativeConstructSchema.audit(native_paths, klass, row)
      warn "  #{verdict.to_s.upcase}  #{klass}  (#{detail})"
    end
    warn ''
  end
  profile_phase.call('closed world + native scans')

  # Only a closed world can enumerate callees: with an open one the analysis stays uninstalled and every
  # consumer keeps its earlier gate. Ruby the build interprets (an outside source this run did not
  # compile) may define any name it spells; the compiled core Ruby is in the ireps.
  if escape_registry && closed_world && closed_world.global_refusal.nil? && closed_world.method_missing_classes.empty?
    escape_aliases = Hash.new { |h, k| h[k] = [] }
    alias_sites.each { |site| escape_aliases[site[:new]] << site[:old] }
    compiled_files = ireps.each_value.to_set(&:file)
    hidden_ruby_names = foreign_method_names(outside_ruby.reject { |path| compiled_files.include?(path) })
    warn "== escape analysis (ADR 0316): #{ireps.size} ireps, #{hidden_ruby_names.size} method names defined by " \
         "Ruby this run does not compile =="
    EscapeAnalysis.install(EscapeAnalysis::World.new(ireps: ireps, defs: escape_registry, aliases: escape_aliases,
                                                     native_names: ENV['NATIVE_SRCS'] ? native_names : nil,
                                                     superclass_of: superclass_of, included: included_modules,
                                                     prepended: prepended_modules, unknown_mixins: unknown_mixins,
                                                     modules: declared_modules, struct_classes: struct_member_lists.keys,
                                                     invisible: lambda { |name|
                                                       hidden_ruby_names.include?(name) || closed_world.unknown_definer?(name)
                                                     }))
  end

  # CORE_VISIBILITY (ADR 0264): a core method is compiled and registered whenever it is
  # eligible, but only one whose name no native method shares (and no fast-path
  # operator, and no guard) is a registry definition, i.e. a dispatch target. Every name-keyed
  # proof and inline path in the compiler models mruby's own method for the names
  # natives define, on the premise that its Ruby definitions cannot be seen; a
  # core definition there would switch them off (FIXNUM_COMPARE, LITERAL ===,
  # ELEM_HINT through `compact`, ...). The others are emitted from CodeGen's
  # `core_hidden_defs`, without becoming candidates.
  # A guarded method (CORE_BLOCK_GUARD, ADR 0269) is never a direct-call target either, so a
  # registry definition of it would only turn every `each`/`map`/`select` proof off.
  core_guarded = CoreMethods.guarded_labels(registry.values.flatten, ireps)
  core_hidden_defs = []
  registry.each do |name, defs|
    next unless defs.any?(&:core)

    if native_names.include?(name) || CoreMethods::OPERATOR_NAMES.include?(name)
      core_hidden_defs.concat(defs.select(&:core))
      defs.reject!(&:core)
    else
      guarded_defs = defs.select { |d| d.core && core_guarded.include?(d.irep) }
      core_hidden_defs.concat(guarded_defs)
      defs.reject! { |d| guarded_defs.include?(d) }
    end
  end
  registry.delete_if { |_, defs| defs.empty? }
  CodeGen.core_hidden_defs = core_hidden_defs
  CodeGen.core_guarded = core_guarded

  warn '== whole-program method registry =='
  registry.sort.each do |name, defs|
    mono = defs.size == 1
    owners = defs.map(&:owner).join(', ')
    warn "  #{mono ? 'MONO' : 'POLY'}  :#{name}  (#{defs.size} def#{'s' unless defs.size == 1}: #{owners})"
  end

  # HOT_ONLY (ADR 0214): set before the first CodeGen, since the probes' embedding
  # and return proofs depend on which bodies compile. Every gem's run reads the
  # same list and registry, so all agree on which `_impl`s exist.
  if ENV['BC2CPP_HOT_METHODS']
    hot_methods = HotMethods.load(ENV['BC2CPP_HOT_METHODS'])
    CodeGen.hot_only_excluded = HotMethods.excluded_labels(registry, hot_methods)
    # A core method that is compiled without being a registry definition is excluded like any other.
    core_hidden_defs.each { |d| CodeGen.hot_only_excluded << d.irep unless hot_methods.include?(HotMethods.key(d)) }
    bytecode_methods = registry.values.flatten.count(&:irep)
    warn ''
    warn "== hot-only (BC2CPP_HOT_METHODS): #{hot_methods.size} listed, #{CodeGen.hot_only_excluded.size} of " \
         "#{bytecode_methods} bytecode methods excluded =="
    HotMethods.stale(registry, hot_methods).each { |k| warn "  STALE #{k}" }
  end

  # CORE_METHODS (ADR 0264): what the core mrblib did to the registry, once. Keyed on the
  # definition's source file, so a fixture that reopens a core class is not affected.
  if core_bytecode.positive? || !core_shadowed.empty?
    warn ''
    warn "== core methods: #{core_bytecode} core-source bytecode methods, #{core_shadowed.size} shadowed by a " \
         "later definition, #{core_ineligible.size} kept interpreted (Fiber, lambda, mruby-enumerator, conditional, refused), " \
         "#{core_hidden_defs.size} compiled without being registry definitions (native or operator name) =="
    core_hidden_defs.map { |d| "#{d.owner}##{d.name}" }.sort.each { |k| warn "  HIDDEN #{k}" }
    core_stale_refusals.each { |k| warn "  STALE #{k}" }
  end

  call_sites = profile_call.call('CallSiteIndex.build') { CallSiteIndex.build(ireps) }
  arg_types = profile_call.call('ArgTypes.analyze') do
    ArgTypes.analyze(ireps, registry, call_sites: call_sites)
  end
  warn ''
  warn '== call-site argument-type inference (MONO names only) =='
  inferred_any = false
  arg_types.each do |name, types|
    types.each_with_index do |t, i|
      next unless t

      inferred_any = true
      warn "  ARG  :#{name}, position #{i + 1}  (#{t})"
    end
  end
  warn '  (none inferred)' unless inferred_any

  annotations = profile_call.call('Annotations.extract') { Annotations.extract(ireps, registry) }
  warn ''
  warn '== magic-comment annotations (# bc2cpp: (T, ...) -> T) =='
  if annotations.empty?
    warn '  (none found)'
  else
    annotations.each do |label, ann|
      d = registry.values.flatten.find { |md| md.irep == label }
      name = d ? "#{d.owner}##{d.name}" : label
      warn "  ANNOTATED  #{name}  (#{ann.args.inspect} -> #{ann.ret.inspect})"
    end
  end

  # INTEGER_CONST_EMBED_SUPPORT / ARRAY_RETURN_IVAR_HINT: foreign sources,
  # foreign method names and integer constants are computed before
  # IvarLayout.analyze (which embeds `@x = SOME_INT_CONST`) and ClassLayout's
  # probing pass (ARRAY_RETURN_PROOF needs foreign_methods). Without
  # NATIVE_SRCS or FOREIGN_RUBY_SRCS both analyses skip and prove nothing extra,
  # rather than run on a knowingly incomplete picture. Diagnostic consumers find
  # sections by header text, not position.
  foreign_ruby_srcs = ENV['FOREIGN_RUBY_SRCS'] ? Shellwords.split(ENV['FOREIGN_RUBY_SRCS']) : nil
  foreign_methods = if foreign_ruby_srcs
                      profile_call.call('foreign_method_names') { foreign_method_names(foreign_ruby_srcs) }
                    end

  # UNIQUE_CLASS_NAME: set before the first ClassLayout pass, since every
  # trace_new_target caller reads it.
  UniqueClassNames.table = profile_call.call('UniqueClassNames.analyze') do
    UniqueClassNames.analyze(ireps, root_label, native_paths, foreign_ruby_srcs)
  end
  UniqueClassNames.object_mixins = Array(included_modules['Object'])
  warn '== bare class names with one definition (UNIQUE_CLASS_NAME) =='
  UniqueClassNames.table.sort.each { |name, full| warn "  UNIQUE_CLASS  #{name}  (#{full})" }

  # LEXICAL_CONSTRUCT_RESOLUTION: the class/module names the closed world
  # DEFINES, so `lexically_resolve_construct_target` can resolve a bare
  # `Window.new` inside `class RPG2k` to RPG2k::Window (a fact about the
  # program) without that resolving to an admission (which stays with
  # compile_send's four live gates). Set next to UniqueClassNames because both
  # read the same CLASS/MODULE walk and must agree on what the bytecode defines.
  ConstructClassNames.table = profile_call.call('ConstructClassNames.analyze') do
    ConstructClassNames.analyze(ireps, root_label, UniqueClassNames.table.values)
  end
  warn "== defined class/module names (LEXICAL_CONSTRUCT_RESOLUTION): #{ConstructClassNames.table.size} =="

  # CLOSED_WORLD_VALUE_CONSTANT: a single class-constructor assignment is a
  # guarded receiver hint, not an unconditional claim about the constant value.
  inferred_constant_classes = profile_call.call('single-assignment value constants') do
    infer_constructed_constant_classes(ireps, constant_assignment_sites, registry, container_constants, closed_world)
  end
  container_constants.merge!(inferred_constant_classes)
  warn "== single-assignment constructed constants (CLOSED_WORLD_VALUE_CONSTANT): #{inferred_constant_classes.size} =="
  inferred_constant_classes.sort.each { |name, klass| warn "  CONST_CLASS  #{name}  (#{klass})" }

  integer_constants =
    if ENV['NATIVE_SRCS'] && foreign_ruby_srcs
      profile_call.call('IntegerConstants.analyze') { IntegerConstants.analyze(ireps, native_paths, foreign_ruby_srcs) }
    else
      Set.new
    end
  warn "== integer-valued constants proven (INTEGER_CONSTANT_PROOF) =="
  if integer_constants.empty?
    warn '  (none)'
  else
    integer_constants.sort.each { |n| warn "  CONST #{n}" }
  end

  integer_constant_values = profile_call.call('IntegerConstants.analyze_values') do
    IntegerConstants.analyze_values(ireps, integer_constants)
  end
  profile_phase.call('global facts + annotations')
  warn "== integer constant literal values proven (INTEGER_CONSTANT_VALUE_PROOF): #{integer_constant_values.size} of #{integer_constants.size} =="
  integer_constant_values.sort.each { |n, v| warn "  CONST #{n} = #{v}" }

  # RECORD_HASH_PROOF (docs/adr/0285): needs the same outside-source picture as
  # IntegerConstants, and a closed world (no open-world caller can see every writer).
  # The trusted tier classifies a writer with the tripwire-backed Array scan
  # the block recognizers already rely on; the default consumer tier is strict.
  record_hash = profile_call.call('RecordHash.analyze') do
    RecordHash.analyze(ireps, registry, native_paths: native_paths, foreign_paths: foreign_ruby_srcs,
                                        closed_world: closed_world,
                                        outside_tokens: (outside_world_tokens(native_paths + foreign_ruby_srcs) if native_paths && foreign_ruby_srcs),
                                        trusted: ->(irep, idx, reg) { proven_array_source_scan(irep, idx, reg.to_s, registry) == 'Array' })
  end
  RecordHash.table = record_hash.table
  RecordHash.readers = record_hash.readers
  warn '== record hash slots (RECORD_HASH_PROOF) =='
  warn "  global refusal: #{record_hash.global_refusal}" if record_hash.global_refusal
  record_hash.slots.sort.each do |name, slot|
    arrays = slot.keys.count { |_, t| t[:strict] == Set['Array'] }
    trusted = slot.keys.count { |_, t| t[:trusted] == Set['Array'] }
    warn "  RECORD_HASH  @#{name}  (#{slot.literals} literal#{'s' unless slot.literals == 1}, #{slot.keys.size} keys, " \
         "#{slot.reads} reads, #{slot.stores} stores; non-nil Array keys: #{arrays} strict, #{trusted} trusted)"
    next unless ENV['BC2CPP_RECORD_HASH_KEYS'] == '1'

    slot.keys.sort.each { |key, t| warn "    :#{key} strict=#{t[:strict].map(&:to_s).sort.join('|')} trusted=#{t[:trusted].map(&:to_s).sort.join('|')}" }
  end
  record_hash.refused.sort.each { |name, why| warn "  RECORD_HASH_REFUSED  @#{name}  (#{why})" }
  warn ''

  # FIXNUM_NIL_DECLARATION: a reviewed "Owner#@ivar" list for the nullable
  # embedding (NILABLE_EMBED_SUPPORT). Opt-in per field, never inferred --
  # see IvarLayout's own comment for the Array-concatenation hole that makes
  # inference unsound. Passed to BOTH IvarLayout passes below.
  fixnum_nil_ivars = ENV['FIXNUM_NIL_IVARS'].to_s
  unless fixnum_nil_ivars.empty?
    warn ''
    warn "== nullable Integer-or-nil ivars declared (FIXNUM_NIL_DECLARATION): #{fixnum_nil_ivars} =="
  end

  # FIXNUM_RETURN_IVAR_HINT: Level 0 IvarLayout (no FIXNUM_RETURN_PROOF evidence).
  # The `== ivar embedding ==` diagnostic is printed later from the final
  # (Level 2) table, so this call is silent.
  ivar_layout = profile_call.call('IvarLayout.analyze initial') do
    IvarLayout.analyze(ireps, registry, arg_types, annotations, integer_constants, nil,
                       fixnum_nil_ivars)
  end
  profile_phase.call('initial ivar layout')

  known_owners = registry.values.flatten.map(&:owner).uniq
  class_annotations = profile_call.call('ClassAnnotations.extract') do
    ClassAnnotations.extract(ireps, registry, known_owners)
  end
  warn ''
  warn '== magic-comment class annotations (# bc2cpp: (ClassName, ...)) =='
  if class_annotations.empty?
    warn '  (none found)'
  else
    class_annotations.each do |label, ann|
      d = registry.values.flatten.find { |md| md.irep == label }
      name = d ? "#{d.owner}##{d.name}" : label
      warn "  CLASS_ANNOTATED  #{name}  (#{ann.args.inspect})"
    end
  end

  warn ''
  warn '== known constant value classes (whole program) =='
  if container_constants.empty?
    warn '  (none)'
  else
    container_constants.sort.each { |name, cls| warn "  CONST_HINT  #{name}  (#{cls})" }
  end

  # ANNOTATED_ARRAY_RETURN_THREADING: CodeGen#annotated_array_return's MONO-keyed
  # lookup, as a lambda because CodeGen does not exist yet at this point.
  annotated_array_return = lambda do |name|
    defs = registry[name]
    next false unless defs && defs.size == 1 && defs.first.irep

    annotations[defs.first.irep]&.ret == :array
  end
  # ANY_OPAQUE_SUPPORT: owner -> {ivar => :any | :opaque}, filled by
  # ClassLayout.analyze (see `poison_reason`) and reported as extra breakdowns of
  # the same candidate list.
  # FIXNUM_RETURN_PROOF / ARRAY_RETURN_PROOF: the foreign poison set, computed
  # here because the probing pass below needs ARRAY_RETURN_PROOF, which proves
  # nothing without it (nil without FOREIGN_RUBY_SRCS).

  # ---------------------------------------------------------------------------
  # ARRAY_RETURN_IVAR_HINT: ClassLayout and ARRAY_RETURN_PROOF depend on each
  # other (compute_array_return_names reads ClassLayout through
  # trace_new_target's GETIV terminal, and ClassLayout's SETIV arm consumes the
  # proof). Naively that admits circular facts:
  #
  #     def initialize; @queue = turn_order; end
  #     def turn_order; @queue; end          # @queue is really nil
  #
  # Stratified: Level 0 = ClassLayout without the proof; Level 1 =
  # ARRAY_RETURN_PROOF against Level 0; Level 2 = ClassLayout with Level 1. Each
  # level uses only the level below, so derivations are well-founded (here
  # @queue stays UNKNOWN). Level 1 is sound given Level 0 (its argument only
  # assumes the ClassLayout facts are true), and Level 2 only adds evidence;
  # disagreeing sites still poison. Monotone: the new evidence only turns
  # UNKNOWN into 'Array', so Level 2 is a superset of Level 0, and everything
  # downstream uses Level 2.
  # Not iterated to a joint fixpoint: sound but a bigger change; stopping early
  # proves less. The real CodeGen still recomputes ARRAY_RETURN_PROOF against
  # Level 2.
  # ---------------------------------------------------------------------------
  class_layout_probe = profile_call.call('ClassLayout.analyze probe') do
    ClassLayout.known(
      ClassLayout.analyze(ireps, registry, class_annotations, container_constants, annotated_array_return,
                          module_body_ivar_labels: module_body_ivar_labels)
    )
  end
  # Built just far enough to answer array_return_names (see CodeGen#initialize's
  # `analysis_only`); the inputs it is not given are never read by
  # compute_array_return_names.
  require_relative 'compiled_gems'
  # BC2CPP_SELF_REGISTERING: BC2CPP_WIRED_EMBEDDINGS exists because a
  # hand-written register.cxx may leave an embedding class's entry point
  # uninstalled (it then runs interpreted against iv_tbl). A caller whose
  # registration is generated from the same `embeds`/`compiled entry points`
  # diagnostic (tools/optcarrot_probe/compiled_run.rb) cannot have that gap and
  # sets this to skip the allowlist; drop_unsafe_embeddings' other checks still
  # run.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  # CORE_MIXINS: the modelled core methods this build's core sources still match.
  CodeGen.core_methods = CoreMixins.verified(foreign_ruby_srcs, native_name_sources)
  CodeGen.core_compare = CoreCompare.verified(foreign_ruby_srcs, native_name_sources)
  warn "== Comparable comparison operators verified against the build's sources (CORE_COMPARE): #{CodeGen.core_compare.to_a.sort.join(', ')} =="
  warn "== core Ruby methods verified against the build's sources (CORE_MIXINS): #{CodeGen.core_methods.to_a.sort.join(', ')} =="
  return_names_probe = CodeGen.new(ireps, registry, ivar_layout, class_layout_probe, class_annotations,
                                    annotations, superclass_of, {}, {}, container_constants, {},
                                    Set.new, foreign_methods, nil, nil,
                                    analysis_only: true,
                                    native_expression_devirt: native_expression_devirt,
                                    native_registered_expressions: native_registered_expressions)
  array_return_probe = profile_call.call('CodeGen.array_return_names probe') { return_names_probe.array_return_names }
  # RETCLASS_SELF_CALL_SUPPORT: from the same Level-0 probe as
  # array_return_probe (see ClassLayout.analyze's `ret_class_proof`).
  class_poison_reason = {}
  # IVAR_POISON_CAUSES: the stores ClassLayout read, kept to classify the unresolved ones after the fixed point.
  ivar_store_log = {}
  class_layout_raw = profile_call.call('ClassLayout.analyze final') do
    ClassLayout.analyze(ireps, registry, class_annotations, container_constants,
                        annotated_array_return, poison_reason: class_poison_reason, store_log: ivar_store_log,
                        array_ret_proof: ->(n) { array_return_probe.include?(n) },
                        ret_class_proof: ->(n, o) { return_names_probe.class_return_for_self_call(n, o) },
                        module_body_ivar_labels: module_body_ivar_labels)
  end
  class_layout = ClassLayout.known(class_layout_raw)
  profile_phase.call('class layout fixed-point passes')
  # Step 6c-bis: the same call-site inference ArgTypes does, for the class-name
  # lattice. Its only consumer is RBS_SEED_CONTRADICTION below -- a class
  # annotation is otherwise consumed purely as a SEED into ClassLayout above, so
  # a wrong one silently becomes the fact it seeded. This is deliberately NOT
  # fed back into ClassLayout or IvarLayout: those are fixed points whose
  # order-independence argument (docs/adr/0139) must not grow a new input.
  owner_of_registry = {}
  registry.each_value { |defs| defs.each { |d| owner_of_registry[d.irep] = d.owner if d.irep } }
  class_arg_types = profile_call.call('ClassArgTypes.analyze') do
    ClassArgTypes.analyze(ireps, registry, owner_of_registry, class_layout, container_constants,
                          call_sites: call_sites)
  end
  warn ''
  warn '== call-site CLASS inference (MONO names only) =='
  if class_arg_types.empty?
    warn '  (none)'
  else
    class_arg_types.sort.each do |name, classes|
      classes.each_with_index do |c, i|
        next unless c

        warn "  CARG  :#{name}, position #{i + 1}  (#{c})"
      end
    end
  end
  warn ''
  warn '== known-ivar-class hints (devirtualization only, never embedded) =='
  if class_layout.empty?
    warn '  (none)'
  else
    class_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  CLASS_HINT  #{klass}#@#{name}  (#{cls})" }
    end
  end

  class_layout_unknowns = ClassLayout.unknowns(class_layout_raw)
  warn ''
  warn '== ivar-class candidates (real SETIV evidence found, but poisoned to unknown) =='
  if class_layout_unknowns.empty?
    warn '  (none)'
  else
    class_layout_unknowns.sort.each { |n| warn "  CLASS_CANDIDATE  #{n}" }
  end

  # ANY_OPAQUE_SUPPORT: :any = two traced sites disagree (not worth annotating);
  # :opaque = some site could not be traced (an annotation candidate).
  warn ''
  warn '== ivar-class candidates split: ANY (proven heterogeneous, not fixable) =='
  any = ClassLayout.unknowns_by_reason(class_layout_raw, class_poison_reason, :any)
  if any.empty?
    warn '  (none)'
  else
    any.sort.each { |n| warn "  CLASS_CANDIDATE_ANY  #{n}" }
  end

  warn ''
  warn '== ivar-class candidates split: OPAQUE (unresolved, may be fixable) =='
  opaque = ClassLayout.unknowns_by_reason(class_layout_raw, class_poison_reason, :opaque)
  if opaque.empty?
    warn '  (none)'
  else
    opaque.sort.each { |n| warn "  CLASS_CANDIDATE_OPAQUE  #{n}" }
  end

  # IVAR_POISON_CAUSES (ADR 0380): the same OPAQUE list bucketed by what the unresolved stores are.
  warn ''
  warn '== ivar-class OPAQUE causes (an ivar counts once, in its first bucket; atoms count it once each) =='
  poison_lines, poison_buckets = IvarPoisonCauses.report(ivar_store_log, opaque, registry)
  poison_lines.each { |l| warn l }
  if ENV['BC2CPP_IVAR_POISON_REPORT']
    File.write(ENV['BC2CPP_IVAR_POISON_REPORT'],
               "#{poison_buckets.flat_map { |bucket, names| names.map { |n| "#{bucket}\t#{n}" } }.join("\n")}\n")
  end

  # ELEMENT_CLASS_SUPPORT: after ClassLayout (only proven-Array ivars are swept)
  # and ClassAnnotations (argument class hints are terminals).
  element_annotations = profile_call.call('ElementAnnotations.extract') do
    ElementAnnotations.extract(ireps, registry, known_owners)
  end
  warn ''
  warn '== magic-comment element annotations (# bc2cpp: ... -> Array<Klass> / -> Klass) =='
  if element_annotations.empty?
    warn '  (none found)'
  else
    element_annotations.each do |label, ann|
      d = registry.values.flatten.find { |md| md.irep == label }
      name = d ? "#{d.owner}##{d.name}" : label
      claim = ann.element ? "Array<#{ann.element}>" : ann.ret_class
      warn "  ELEM_ANNOTATED  #{name}  (-> #{claim})"
    end
  end

  # ANY_OPAQUE_SUPPORT: as class_poison_reason.
  element_poison_reason = {}
  element_raw = profile_call.call('ArrayElementLayout.analyze') do
    ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                               element_annotations, superclass_of,
                               poison_reason: element_poison_reason,
                               closed_world: closed_world, included_modules: included_modules,
                               prepended_modules: prepended_modules, unknown_mixins: unknown_mixins)
  end
  element_layout = ArrayElementLayout.known(element_raw)
  warn ''
  warn '== known-array-element-class hints (guarded devirtualization only) =='
  if element_layout.empty?
    warn '  (none)'
  else
    element_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  ELEM_HINT  #{klass}#@#{name}  (Array<#{cls}>)" }
    end
  end

  # PRIMITIVE_ELEMENT_SUPPORT: ivars whose elements are primitive tags;
  # informational, excluded from element_layout/ELEM_HINT (see
  # ArrayElementLayout.primitives).
  element_primitives = ArrayElementLayout.primitives(element_raw)
  warn ''
  warn '== known-array-element PRIMITIVE hints (informational only, never embedded) =='
  if element_primitives.empty?
    warn '  (none)'
  else
    element_primitives.each do |klass, ivars|
      ivars.each { |name, cls| warn "  ELEM_HINT_PRIMITIVE  #{klass}#@#{name}  (Array<#{cls}>)" }
    end
  end

  element_unknowns = ArrayElementLayout.unknowns(element_raw)
  warn ''
  warn '== array-element candidates (proven-Array ivar, element class poisoned to unknown) =='
  if element_unknowns.empty?
    warn '  (none)'
  else
    element_unknowns.each { |n| warn "  ELEM_CANDIDATE  #{n}" }
  end

  warn ''
  warn '== array-element candidates split: ANY (proven heterogeneous, not fixable) =='
  elem_any = ArrayElementLayout.unknowns_by_reason(element_raw, element_poison_reason, :any)
  if elem_any.empty?
    warn '  (none)'
  else
    elem_any.sort.each { |n| warn "  ELEM_CANDIDATE_ANY  #{n}" }
  end

  warn ''
  warn '== array-element candidates split: OPAQUE (unresolved, may be fixable) =='
  elem_opaque = ArrayElementLayout.unknowns_by_reason(element_raw, element_poison_reason, :opaque)
  if elem_opaque.empty?
    warn '  (none)'
  else
    elem_opaque.sort.each { |n| warn "  ELEM_CANDIDATE_OPAQUE  #{n}" }
  end

  # HASH_ELEMENT_SUPPORT: after ArrayElementLayout, so values chained through a
  # known-element array resolve (see HashElementLayout.analyze).
  # ANY_OPAQUE_SUPPORT: as class_poison_reason.
  hash_poison_reason = {}
  hash_element_raw = profile_call.call('HashElementLayout.analyze') do
    HashElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                              element_annotations, element_raw, superclass_of,
                              poison_reason: hash_poison_reason,
                              closed_world: closed_world, included_modules: included_modules,
                              prepended_modules: prepended_modules, unknown_mixins: unknown_mixins)
  end
  hash_element_layout = HashElementLayout.known(hash_element_raw)
  profile_phase.call('array/hash element layouts')
  warn ''
  warn '== known-hash-element-class hints (guarded devirtualization only) =='
  if hash_element_layout.empty?
    warn '  (none)'
  else
    hash_element_layout.each do |klass, ivars|
      ivars.each { |name, cls| warn "  HASH_ELEM_HINT  #{klass}#@#{name}  (Hash<#{cls}>)" }
    end
  end

  # PRIMITIVE_ELEMENT_SUPPORT: as element_primitives.
  hash_element_primitives = HashElementLayout.primitives(hash_element_raw)
  warn ''
  warn '== known-hash-element PRIMITIVE hints (informational only, never embedded) =='
  if hash_element_primitives.empty?
    warn '  (none)'
  else
    hash_element_primitives.each do |klass, ivars|
      ivars.each { |name, cls| warn "  HASH_ELEM_HINT_PRIMITIVE  #{klass}#@#{name}  (Hash<#{cls}>)" }
    end
  end

  hash_element_unknowns = HashElementLayout.unknowns(hash_element_raw)
  warn ''
  warn '== hash-element candidates (proven-Hash ivar, value class poisoned to unknown) =='
  if hash_element_unknowns.empty?
    warn '  (none)'
  else
    hash_element_unknowns.each { |n| warn "  HASH_ELEM_CANDIDATE  #{n}" }
  end

  warn ''
  warn '== hash-element candidates split: ANY (proven heterogeneous, not fixable) =='
  hash_any = HashElementLayout.unknowns_by_reason(hash_element_raw, hash_poison_reason, :any)
  if hash_any.empty?
    warn '  (none)'
  else
    hash_any.sort.each { |n| warn "  HASH_ELEM_CANDIDATE_ANY  #{n}" }
  end

  warn ''
  warn '== hash-element candidates split: OPAQUE (unresolved, may be fixable) =='
  hash_opaque = HashElementLayout.unknowns_by_reason(hash_element_raw, hash_poison_reason, :opaque)
  if hash_opaque.empty?
    warn '  (none)'
  else
    hash_opaque.sort.each { |n| warn "  HASH_ELEM_CANDIDATE_OPAQUE  #{n}" }
  end

  candidates = report_annotation_candidates(ireps, registry, arg_types, annotations)
  warn ''
  warn '== annotation candidates (opaque incoming argument, unresolved) =='
  if candidates.empty?
    warn '  (none)'
  else
    candidates.each do |c|
      target = c[:ivar] ? "-> @#{c[:ivar]}" : "-> (used in #{c[:via]})"
      warn "  CANDIDATE  #{c[:owner]}##{c[:name]}, arg #{c[:pos]}/#{c[:mand]} #{target}"
    end
  end

  # `annotations` also drives NATIVE_ARG_TARGETS.
  # FIXNUM_RETURN_PROOF: without FOREIGN_RUBY_SRCS this is nil (never an empty
  # set), which compute_fixnum_return_names reads as "no scan" and proves
  # nothing.
  # ENTRY_ARG_CALLSITE_PROOF: every identifier token from the same two inputs
  # (see outside_world_tokens); nil when either is absent.
  outside_tokens =
    if native_paths && foreign_ruby_srcs
      outside_world_tokens(native_paths + foreign_ruby_srcs)
    end
  # NUMERIC_OPERAND_PROOF: the same two outside inputs, as ivar names they spell
  # and operators they define on NilClass; nil when either input is absent.
  outside_ivars = (outside_ivar_names(native_paths + foreign_ruby_srcs) if native_paths && foreign_ruby_srcs)
  native_ivar_scopes = {}
  if closed_world && native_paths && foreign_ruby_srcs
    native_ivar_scopes, refusal = NativeIvarScopes.analyze(native_paths + outside_native, foreign_ruby_srcs + outside_ruby)
    warn "== native ivar scopes (ADR 0332): #{refusal || native_ivar_scopes.inspect} =="
  end
  nil_operators = (nil_class_operator_names(native_paths) if native_paths && foreign_ruby_srcs)
  outside_consts = if native_paths && foreign_ruby_srcs
                     IntegerConstants.native_defined_const_names(native_paths) |
                       IntegerConstants.foreign_const_names(foreign_ruby_srcs)
                   end
  warn ''
  # BC2CPP_SELF_REGISTERING: same guard as for the probing CodeGen above.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.stable_class_constants = profile_call.call('StableClassConstants.analyze') do
    StableClassConstants.analyze(ireps, native_paths, foreign_ruby_srcs) |
      StableClassConstants.analyze_native(ireps, native_paths, foreign_ruby_srcs)
  end
  warn "== stable class constants (CONST_SITE_CACHE): #{CodeGen.stable_class_constants.size} =="
  # COMPUTED_SEND_EXPANSION (ADR 0303): frozen Symbol tables a computed-name send may index.
  CodeGen.computed_send_tables = profile_call.call('ComputedSendNames::SymbolTables.analyze') do
    ComputedSendNames::SymbolTables.analyze(ireps, native_paths, foreign_ruby_srcs)
  end
  warn "== frozen Symbol tables (COMPUTED_SEND_EXPANSION): #{CodeGen.computed_send_tables.size} =="
  CodeGen.computed_send_tables.sort.each { |n, names| warn "  SYMBOL_TABLE #{n}  (#{names.size} names)" }
  CodeGen.struct_members = struct_member_lists
  warn "== Struct.new owners with a known member list (STRUCT_INDEX_CACHE): #{CodeGen.struct_members.size} =="
  CodeGen.integer_constant_values = integer_constant_values
  # NUMERIC_CONSTANT_RANGES (ADR 0318); BC2CPP_NUMERIC_CONSTANTS=0 computes nothing, so the output is master's.
  CodeGen.integer_constant_ranges =
    if IntegerConstantRanges.enabled? && native_paths && foreign_ruby_srcs
      range_report = ENV['BC2CPP_NUMERIC_CONSTANTS_REPORT'] ? [] : nil
      ranges = profile_call.call('IntegerConstantRanges.analyze') do
        IntegerConstantRanges.analyze(ireps, native_paths, foreign_ruby_srcs, report: range_report)
      end
      File.write(ENV.fetch('BC2CPP_NUMERIC_CONSTANTS_REPORT'), "#{range_report.sort.join("\n")}\n") if range_report
      ranges
    end
  warn "== constants with a proven Fixnum interval (NUMERIC_CONSTANT_RANGES): #{CodeGen.integer_constant_ranges&.size.to_i} =="
  (CodeGen.integer_constant_ranges || {}).sort.each { |n, (lo, hi)| warn "  CONST_RANGE #{n} #{lo} #{hi}" }
  CodeGen.stable_class_constants.sort.each { |n| warn "  STABLE_CLASS #{n}" }

  # ---------------------------------------------------------------------------
  # FIXNUM_RETURN_IVAR_HINT: IvarLayout and FIXNUM_RETURN_PROOF depend on each
  # other (trace_type's SEND case trusts a proven Fixnum return, and that proof's
  # source 3 reads @ivar_layout), e.g. optcarrot's `@_pc =
  # peek16(RESET_VECTOR)` where peek16 is proven only through ivar reads.
  # Stratified like ARRAY_RETURN_IVAR_HINT: Level 0 = `ivar_layout` as computed
  # above; Level 1 = FIXNUM_RETURN_PROOF from a probing CodeGen on Level 0
  # (`analysis_only: :fixnum_return`), with every other table already final
  # (none of them take ivar_layout); Level 2 = IvarLayout.analyze with Level 1
  # available to trace_type's SEND arm, passed to the real CodeGen.
  # Sound: Level 1 is the unchanged proof run on a subset of the final ivar
  # facts (never more permissive). Level 2 only turns UNKNOWN SEND sites into
  # :fixnum (guarded by MONO uniqueness), so it is a superset of Level 0. Not
  # iterated further, for the reasons given for ARRAY_RETURN_IVAR_HINT; the real
  # CodeGen recomputes FIXNUM_RETURN_PROOF against Level 2.
  # ---------------------------------------------------------------------------
  fixnum_return_probe = profile_call.call('CodeGen.fixnum_return_names probe') do
    CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations,
                superclass_of, element_layout, element_annotations, container_constants,
                hash_element_layout, integer_constants, foreign_methods, outside_tokens,
                native_name_sources, included_modules, prepended_modules, unknown_mixins,
                analysis_only: :fixnum_return,
                native_expression_devirt: native_expression_devirt,
                native_registered_expressions: native_registered_expressions).fixnum_return_names
  end
  all_ivars = profile_call.call('IvarLayout.all final') { IvarLayout.all(ireps, registry) }
  typed_ivars = profile_call.call('IvarLayout.analyze final') do
    IvarLayout.analyze(ireps, registry, arg_types, annotations, integer_constants,
                       fixnum_return_probe, fixnum_nil_ivars)
  end
  ivar_layout = {}
  all_ivars.each do |klass, ivars|
    ivar_layout[klass] = ivars.to_h do |name, fallback_type|
      [name, typed_ivars.dig(klass, name) || fallback_type]
    end
  end
  profile_phase.call('return/fixnum proofs + final ivars')
  warn ''
  warn '== ivar embedding =='
  if ivar_layout.empty?
    warn '  (none embeddable)'
  else
    ivar_layout.each do |klass, ivars|
      ivars.each { |name, type| warn "  EMBED  #{klass}#@#{name}  (#{type})" }
    end
  end

  gen = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations, superclass_of,
                    element_layout, element_annotations, container_constants, hash_element_layout,
                    integer_constants, foreign_methods, outside_tokens, native_name_sources,
                    included_modules, prepended_modules, unknown_mixins,
                    native_expression_devirt: native_expression_devirt,
                    native_registered_expressions: native_registered_expressions,
                    closed_world: closed_world, outside_ivar_names: outside_ivars,
                    native_ivar_scopes: native_ivar_scopes,
                    nil_operator_names: nil_operators, outside_const_names: outside_consts)
  warn '== typed slots demoted to boxed slots (foreign writers, ADR 0279) =='
  if gen.typed_demotions.empty?
    warn '  (none)'
  else
    gen.typed_demotions.sort.each { |(owner, name), why| warn "  BOXED  #{owner}#@#{name}  (#{why})" }
  end
  warn ''
  warn '== methods proven Fixnum-returning (FIXNUM_RETURN_PROOF) =='
  if gen.fixnum_return_names.empty?
    warn '  (none)'
  else
    gen.fixnum_return_names.sort.each { |n| warn "  RET #{n}" }
  end
  warn ''
  # RBS_SEED_CONTRADICTION: a hand-written `# bc2cpp:` annotation that disagrees
  # with a type the analysis PROVED is a build error, Spinel's rule for a
  # representable RBS signature ("an assertion, not a hint"). Without it a typo
  # in an annotation costs an optimization in silence, which is the same class
  # of failure as a stale registration. Only a concrete inferred type can
  # contradict: UNKNOWN is an absent fact, not a conflicting one, so an
  # annotation that merely failed to apply still passes.
  contradictions = AnnotationContradictions.find(ireps, registry, annotations, arg_types,
                                                gen.fixnum_return_names, class_annotations,
                                                class_arg_types)
  warn '== annotation/proof contradictions (RBS_SEED_CONTRADICTION) =='
  if contradictions.empty?
    warn '  (none)'
  else
    contradictions.each do |owner, name, pos, declared, got|
      where = pos == :return ? 'return' : "position #{pos + 1}"
      warn "  CONTRADICTION #{owner}##{name} #{where}: annotation says #{declared.inspect}, " \
           "inference proved #{got.inspect}"
    end
    abort "\n[bc2pp] RBS_SEED_CONTRADICTION: #{contradictions.size} annotation(s) disagree with a " \
          "proved type (see above). Fix the annotation, or the code it claims to describe."
  end
  warn ''
  # ARRAY_RETURN_PROOF listing, one line per name like the one above, so the
  # coverage report can count it. See CodeGen#compute_array_return_names.
  warn '== methods proven Array-returning (ARRAY_RETURN_PROOF) =='
  if gen.array_return_names.empty?
    warn '  (none)'
  else
    gen.array_return_names.sort.each { |n| warn "  ARET #{n}" }
  end
  warn ''
  # ENTRY_ARG_CALLSITE_PROOF: one line per (method, position), by owner/name.
  warn '== entry arguments proven Fixnum by call-site enumeration (ENTRY_ARG_CALLSITE_PROOF) =='
  entry_arg_facts = gen.entry_arg_fixnum_facts
  if entry_arg_facts.empty?
    warn '  (none)'
  else
    owner_by_irep = {}
    registry.each_value { |defs| defs.each { |d| owner_by_irep[d.irep] = d if d.irep } }
    entry_arg_facts.map do |(label, k)|
      d = owner_by_irep[label]
      d ? "  ARG #{d.owner}##{d.name} arg#{k}" : "  ARG <irep #{label}> arg#{k}"
    end.sort.each { |l| warn l }
  end
  warn ''
  # NUMERIC_OPERAND_PROOF (ADR 0276): the whole-program facts behind the
  # dynamic-send-free arithmetic/compare arms.
  warn '== numeric operand facts (NUMERIC_OPERAND_PROOF) =='
  gen.numeric_facts_report.each { |l| warn l }
  warn ''
  # LCF_ROW_FLOW (ADR 0294): whether the LCF object-kind proof is on, and why not.
  warn '== LCF row flow (LCF_ROW_FLOW) =='
  warn(gen.lcf_rows_model ? "  on (#{gen.lcf_rows_model.kinds.size} kinds)" : "  off: #{gen.lcf_rows_refusal}")
  warn ''
  # FROZEN_TABLES (ADR 0306): frozen Array/Hash literals whose slot classes are tracked.
  warn '== frozen tables (FROZEN_TABLES) =='
  warn(gen.frozen_tables_model ? "  on (#{gen.frozen_tables_model.shapes.size} shapes)" : "  off: #{gen.frozen_tables_refusal}")
  gen.frozen_tables_report.each { |l| warn l }
  warn ''
  # RETURN_CLASS_TABLE (ADR 0289): names whose every definition returns one exact class.
  warn '== return class table (RETURN_CLASS_TABLE) =='
  gen.return_class_report.each { |l| warn l }
  warn ''
  # CLASS_POOLS (ADR 0295): ivar and argument class sets pooled across methods.
  warn '== class pools (CLASS_POOLS) =='
  gen.class_pool_report.each { |l| warn l }
  warn ''
  # POOL_DROP_REPORT (ADR 0380): why the ivar pools that are not there are not there.
  if ENV['BC2CPP_POOL_DROP_REPORT']
    warn '== class pools dropped: causes (POOL_DROP_REPORT) =='
    gen.pool_drop_report.each { |l| warn l }
    warn ''
  end
  # CONSTRUCTOR_POOLS (ADR 0313): initialize arguments joined over every constructor site.
  warn '== constructor pools (CONSTRUCTOR_POOLS) =='
  gen.constructor_pool_report.each { |l| warn l }
  warn ''
  # ONLY_OWNERS narrows emitted code (e.g. "LCF::File,LCF::Database"), not the
  # registry: srcs must still be the whole program (see compile_all).
  only_owners = ENV['ONLY_OWNERS']&.split(',')
  # OTHER_OWNERS: classes another gem's run compiles and exposes (with
  # OTHER_DECLS_HEADER); see compile_send.
  other_owners = ENV['OTHER_OWNERS']&.split(',')
  compiled = profile_call.call('CodeGen.compile_all') do
    gen.compile_all(only_owners: only_owners, other_owners: other_owners)
  end
  compiled += gen.emit_synthesized_accessors(only_owners: only_owners)
  profile_phase.call('compile all methods')

  # SKIP_UNSUPPORTED=1 drops methods containing `#error` from the output; they
  # stay interpreted. CLI exploration keeps the markers visible; real builds
  # (mrbgem.rake) set this, since a `#error` stops the C++ build.
  unsupported_core_codes = compiled.select { |m| m[:code].include?('#error') && m[:label] && CoreDefs.core_source?(ireps[m[:label]]&.file) }
  if ENV['SKIP_UNSUPPORTED'] == '1'
    skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }
    unless skipped.empty?
      warn ''
      warn '== skipped (unsupported, left on the interpreter) =='
      skipped.each { |m| warn "  #{m[:owner]}##{m[:name]}" }
    end
  end

  # CORE_INTERPRETED_REPORT (ADR 0371): every core-source bytecode method this run leaves
  # interpreted, with the reason and the language features it uses.
  if core_bytecode.positive?
    unsupported = unsupported_core_codes.to_h do |m|
      key = "#{m[:owner]}##{m[:name]}"
      [key, m[:code][/^\s*#error (.*?) -- not in this/, 1].to_s.delete_prefix("#{key} ")]
    end
    report = CoreMethods.interpreted_report(core_all_defs, ireps, core_refused, unsupported)
    warn ''
    warn "== core-source methods left interpreted (#{report.size}) =="
    report.each { |l| warn "  #{l}" }
  end

  # HOT_ONLY: listed methods that still did not compile run as bytecode; name
  # them so a profile regeneration can see it.
  if hot_methods
    compiled_keys = compiled.to_set { |m| "#{m[:owner]}##{m[:name]}" }
    lost = registry.values.flatten.select do |d|
      d.irep && (!only_owners || only_owners.include?(d.owner)) && hot_methods.include?(HotMethods.key(d)) &&
        !compiled_keys.include?(HotMethods.key(d))
    end
    warn ''
    warn "== hot-only: listed but not compiled (#{lost.size}) =="
    lost.map { |d| HotMethods.key(d) }.uniq.sort.each { |k| warn "  NOT_COMPILED #{k}" }
  end

  # SITE_PROFILE (ADR 0298): opt-in counters on by-name dispatch; unset leaves stdout untouched.
  if (site_profile_dir = ENV['BC2CPP_SITE_PROFILE']) && !site_profile_dir.empty?
    require_relative 'site_profile'
    SiteProfile.capture_stdout(site_profile_dir, symbol)
  end

  # PARAM_TRACE (tools/bc2cpp/param_trace.rb): opt-in runtime classes of compiled method and block
  # parameters; unset (or any value but 1) leaves stdout untouched. Registered BEFORE ELSE_TRACE so the
  # else trace instruments the plain text first (at_exit runs last-in first-out).
  if ENV['BC2CPP_TRACE_PARAMS'] == '1'
    require_relative 'param_trace'
    ParamTrace.capture_stdout(
      symbol,
      ParamTrace.method_infos(compiled, ireps: ireps, registry: registry, arg_types: arg_types,
                                        class_arg_types: class_arg_types, annotations: annotations, gen: gen)
    )
  end

  # ELSE_TRACE (tools/bc2cpp/else_trace.rb): opt-in counters on the else arm of a core class-tag chain;
  # unset (or any value but 1) leaves stdout untouched.
  if ENV['BC2CPP_TRACE_ELSE'] == '1'
    if ENV['BC2CPP_SITE_PROFILE'] && !ENV['BC2CPP_SITE_PROFILE'].empty?
      abort 'bc2cpp: BC2CPP_TRACE_ELSE and BC2CPP_SITE_PROFILE both rewrite bc2cpp_send; set one of them'
    end
    require_relative 'else_trace'
    ElseTrace.capture_stdout(symbol, compiled.to_h { |m| [m[:impl], "#{m[:owner]}##{m[:name]}"] })
  end

  puts '#include <mruby.h>'
  puts '#include <stddef.h>'
  puts '#include <string.h>'
  # isnan/isinf/floor/ceil for to_i's Float case (TO_I_TYPE_TAG_DISPATCH).
  puts '#include <math.h>'
  puts '#include <mruby/numeric.h>'
  puts '#include <mruby/string.h>'
  puts '#include <mruby/variable.h>'
  puts '#include <mruby/data.h>'
  puts '#include <mruby/hash.h>'
  puts '#include <mruby/array.h>'
  puts '#include <mruby/class.h>'
  # mrb_range_new for RANGE_INC/RANGE_EXC.
  puts '#include <mruby/range.h>'
  # mrb_protect_error for GETCONST's owner-scope-first lookup (core API, not the
  # mruby-error gem).
  puts '#include <mruby/error.h>'
  # mruby/io.h is a mrbgem-only include path. The optional helper declaration
  # stays in generated code so core-only fixtures do not need that header.
  puts '#ifdef HAVE_MRUBY_IO_GEM'
  puts 'extern "C" mrb_bool mrb_io_puts_direct(mrb_state*, mrb_value, mrb_int, const mrb_value*, mrb_value*);'
  puts '#endif'
  # mrb_proc_new_cfunc for BLOCK_CFUNC_FALLBACK_SUPPORT; this header has a
  # C-linkage guard, so a plain #include is fine.
  puts '#include <mruby/proc.h>'
  # EXCEPTION_BREAK_SUPPORT: the exception a BLOCK_FALLBACK BREAK throws and the
  # call-site glue catches (mruby is built with MRB_USE_CXX_EXCEPTION). Always
  # emitted: a header-only struct with nothing to link.
  # BLOCK_SEMANTICS (ADR 0266): each carries the token of the frame it unwinds
  # to, so a catch takes only its own.
  puts 'struct bc2cpp_block_break { mrb_value value; mrb_int token; };'
  # EXCEPTION_RETURN_SUPPORT: a DIFFERENT type from bc2cpp_block_break, so the
  # method-level catch and the per-call-site catch never catch each other's
  # exception (exact C++ catch matching).
  puts 'struct bc2cpp_method_return { mrb_value value; mrb_int token; };'
  # A `break` or `return` of a strict proc (Kernel#lambda over a block) only
  # leaves the proc; caught by its entry function.
  puts 'struct bc2cpp_proc_exit { mrb_value value; };'
  # VM_UNWIND_RESTORE: bc2cpp_block_break / bc2cpp_method_return are foreign
  # C++ exceptions, which mruby's own MRB_TRY/MRB_CATCH (`catch (mrb_jmpbuf*)`)
  # does not intercept. When one unwinds through real VM frames (a compiled block
  # that returns or breaks out of a Ruby-defined iterator such as `each`),
  # mrb_vm_exec/mrb_funcall_with_block never run their cleanup: mrb->jmp points
  # at a dead frame and the callinfo stack keeps every frame pushed since, which
  # trips mrb_vm_run's `c->ci == c->cibase || ...` assertion. Every catch site
  # takes a mark before its `try` and restores it here, as mrb_protect_error does
  # for an mruby exception: reset mrb->jmp and pop the leftover callinfos,
  # unsharing each popped frame's env as the VM's cipop does.
  puts <<~'CPP'
    struct Bc2cppVmMark { struct mrb_jmpbuf* jmp; ptrdiff_t ci_index; };
    static inline Bc2cppVmMark bc2cpp_vm_mark(mrb_state* M) {
      return { M->jmp, M->c->ci - M->c->cibase };
    }
    static void bc2cpp_vm_restore(mrb_state* M, const Bc2cppVmMark& mark) {
      M->jmp = mark.jmp;
      struct mrb_context* c = M->c;
      while (c->ci - c->cibase > mark.ci_index) {
        mrb_callinfo* ci = c->ci;
        mrb_vm_ci_env_clear(M, ci);
        struct RProc* blk = ci->blk;
        if (blk && !MRB_PROC_STRICT_P(blk) && MRB_PROC_ENV(blk) == mrb_vm_ci_env(&ci[-1])) {
          blk->flags |= MRB_PROC_ORPHAN;
        }
        c->ci--;
      }
      if (M->errinfo && (c->ci - c->cibase) < M->errinfo_ci_depth) M->errinfo = NULL;
    }
    // BLOCK_SEMANTICS (ADR 0266): a cfunc-backed Proc (every BLOCK_FALLBACK
    // block) cannot be reached through Proc#call from a compiled frame: OP_CALL
    // pops back to that cfunc frame and reads ci->proc->body.irep, which is NULL
    // there. Such a call yields to the proc directly, as OP_BLKCALL does.
    static bool bc2cpp_cfunc_proc_call_p(mrb_state* M, mrb_value recv, mrb_sym mid) {
      if (!MRB_PROC_CFUNC_P(mrb_proc_ptr(recv)) || mrb_obj_ptr(recv)->c != M->proc_class) return false;
      const char* name = mrb_sym_name(M, mid);
      if (!name || !(!strcmp(name, "call") || !strcmp(name, "yield") || !strcmp(name, "[]") || !strcmp(name, "==="))) return false;
      // Only where the name is Proc's own bytecode method: without mruby-proc-ext
      // `===` is Object's, and `[]` may be missing altogether.
      struct RClass* found = M->proc_class;
      mrb_method_t m = mrb_method_search_vm(M, &found, mid);
      return !MRB_METHOD_UNDEF_P(m) && found == M->proc_class && !MRB_METHOD_CFUNC_P(m);
    }
    // ADR 0266: a break or return may only unwind to a frame still on the C++
    // stack; the frames that can be one are chained, each with a token that a
    // block keeps in its env. A block outliving its frame (a stored or returned
    // proc) finds no live token and raises LocalJumpError, as the VM does.
    // Tokens are 30-bit serials, so a stale one matches a live frame only after
    // 2^30 frames.
    struct Bc2cppFrame { mrb_int token; Bc2cppFrame* parent; };
    static Bc2cppFrame* bc2cpp_break_frames = nullptr;
    static Bc2cppFrame* bc2cpp_return_frames = nullptr;
    static mrb_int bc2cpp_frame_serial = 0;
    struct Bc2cppFrameGuard {
      Bc2cppFrame frame;
      Bc2cppFrame** head;
      explicit Bc2cppFrameGuard(Bc2cppFrame** h) : head(h) {
        bc2cpp_frame_serial = bc2cpp_frame_serial % 0x3fffffff + 1;
        frame.token = bc2cpp_frame_serial;
        frame.parent = *h;
        *h = &frame;
      }
      ~Bc2cppFrameGuard() { *head = frame.parent; }
      Bc2cppFrameGuard(const Bc2cppFrameGuard&) = delete;
      Bc2cppFrameGuard& operator=(const Bc2cppFrameGuard&) = delete;
    };
    static bool bc2cpp_frame_live(const Bc2cppFrame* head, mrb_value token) {
      if (!mrb_integer_p(token)) return false;
      for (const Bc2cppFrame* f = head; f; f = f->parent) if (f->token == mrb_integer(token)) return true;
      return false;
    }
    // The method frame a block built right now returns to; 0 (never live) if none.
    static inline mrb_value bc2cpp_return_token(mrb_state* M) {
      return mrb_int_value(M, bc2cpp_return_frames ? bc2cpp_return_frames->token : 0);
    }
    [[noreturn]] static void bc2cpp_break(mrb_state* M, mrb_value value, mrb_value token) {
      if (!bc2cpp_frame_live(bc2cpp_break_frames, token)) {
        mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "break from proc-closure");
      }
      throw bc2cpp_block_break{ value, mrb_integer(token) };
    }
    [[noreturn]] static void bc2cpp_return_from_block(mrb_state* M, mrb_value value, mrb_value token) {
      if (!bc2cpp_frame_live(bc2cpp_return_frames, token)) {
        mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "unexpected return");
      }
      throw bc2cpp_method_return{ value, mrb_integer(token) };
    }
    // ADR 0266: OP_ENTER reports every positional arity error as `expected
    // <mandatory>` (vm.c argnum_error); mrb_get_args would say `1+` or `1..2`.
    // A call carrying keywords is left to mrb_get_args, which folds them in.
    static inline void bc2cpp_check_argc(mrb_state* M, mrb_int min, mrb_int max) {
      mrb_int argc = mrb_get_argc(M);
      if (M->c->ci->nk == 0 && (argc < min || (max >= 0 && argc > max))) mrb_argnum_error(M, argc, min, min);
    }
    // Kernel#lambda flags a copy of the RProc strict after the block was built.
    static inline bool bc2cpp_proc_strict_p(mrb_state* M) {
      const struct RProc* p = M->c->ci->proc;
      return p && MRB_PROC_STRICT_P(p);
    }
    // BLOCK_DIRECT_ENTRY (ADR 0271): a compiled block without break or return has a direct entry
    // taking its captured environment and arguments. Its proc is a cfunc proc over this one
    // function (inline: one address in every translation unit of the link) with the entry as the
    // second-to-last env slot, so a yield from compiled code calls the entry without a VM frame, and
    // anything else (an interpreted iterator, a Fiber) reaches it through the VM like any cfunc.
    typedef mrb_value (*Bc2cppBlockEntry)(mrb_state*, struct REnv*, bool, mrb_int, const mrb_value*);
    static inline Bc2cppBlockEntry bc2cpp_block_entry(struct REnv* e) {
      return reinterpret_cast<Bc2cppBlockEntry>(static_cast<uintptr_t>(mrb_integer(e->stack[MRB_ENV_LEN(e) - 2])));
    }
    inline mrb_value bc2cpp_block_thunk(mrb_state* M, mrb_value) {
      mrb_value* argv;
      mrb_int argc;
      mrb_get_args(M, "*", &argv, &argc);
      const struct RProc* p = M->c->ci->proc;
      return bc2cpp_block_entry(MRB_PROC_ENV(p))(M, MRB_PROC_ENV(p), MRB_PROC_STRICT_P(p), argc, argv);
    }
    // YIELD_REACH (ADR 0283): the last env slot of a direct-entry block says its body, and everything
    // it can call, provably never suspends a Fiber. A compiled core iterator running such a block
    // may then stay compiled under a Fiber (its frame cannot be crossed by a yield).
    static inline bool bc2cpp_block_yield_free(mrb_value blk) {
      if (mrb_type(blk) != MRB_TT_PROC) return false;
      const struct RProc* p = mrb_proc_ptr(blk);
      if (!MRB_PROC_CFUNC_P(p) || MRB_PROC_CFUNC(p) != bc2cpp_block_thunk) return false;
      const struct REnv* e = MRB_PROC_ENV(p);
      return mrb_integer(e->stack[MRB_ENV_LEN(e) - 1]) != 0;
    }
    // SETUPVAR writes into the enclosing compiled frame, which the GC cannot see; the arena that
    // held the value is restored when the block returns (ADR 0272). Roots stay per slot address.
    static inline void bc2cpp_upvar_root(mrb_state* M, mrb_value* slot, mrb_value v) {
      if (mrb_immediate_p(v)) return;
      mrb_sym id = mrb_intern_lit(M, "$__bc2cpp_upvar_roots");
      mrb_value roots = mrb_gv_get(M, id);
      if (!mrb_hash_p(roots)) {
        roots = mrb_hash_new(M);
        mrb_gv_set(M, id, roots);
      }
      mrb_hash_set(M, roots, mrb_int_value(M, (mrb_int)((uintptr_t)slot >> 2)), v);
    }
    // mrb_yield_argv, minus the frame when `blk` is a non-strict block with a direct entry. The
    // arena is restored and the result protected as mrb_yield_with_class does.
    static inline mrb_value bc2cpp_yield_argv(mrb_state* M, mrb_value blk, mrb_int argc, const mrb_value* argv) {
      if (mrb_type(blk) == MRB_TT_PROC) {
        struct RProc* p = mrb_proc_ptr(blk);
        if (MRB_PROC_CFUNC_P(p) && MRB_PROC_CFUNC(p) == bc2cpp_block_thunk && !MRB_PROC_STRICT_P(p)) {
          struct REnv* e = MRB_PROC_ENV(p);
          int ai = mrb_gc_arena_save(M);
          mrb_value result = bc2cpp_block_entry(e)(M, e, false, argc, argv);
          mrb_gc_arena_restore(M, ai);
          mrb_gc_protect(M, result);
          return result;
        }
      }
      return mrb_yield_argv(M, blk, argc, argv);
    }
    static inline mrb_value bc2cpp_funcall_argv(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv) {
      if (mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
      return mrb_funcall_argv(M, recv, mid, argc, argv);
    }
  CPP
  # IO_PUTS_MODEL (ADR 0284): one shared body for every explicit-receiver `puts`, so the
  # by-name fallback exists once instead of once per site.
  puts <<~'IO_PUTS'
    static inline mrb_value bc2cpp_io_puts(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv) {
    #ifdef HAVE_MRUBY_IO_GEM
      mrb_value result;
      if (mrb_io_puts_direct(M, recv, argc, argv, &result)) return result;
    #endif
      return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    }
  IO_PUTS
  # ENSURE_RAII_SUPPORT: the runtime guard for a recognized `ensure`
  # (recognize_ensure_region / emit_ensure_guard_open). A C++ destructor runs on
  # every exit:
  #   - fall-through and `return` (the operand is evaluated first, so a plain
  #     ensure cannot change the returned value, as in Ruby);
  #   - this file's bc2cpp_block_break / bc2cpp_method_return unwinding;
  #   - a Ruby `raise`: only because mruby is built with MRB_USE_CXX_EXCEPTION,
  #     so MRB_THROW is a real C++ `throw (mrb_jmpbuf*)` (mruby/throw.h). With
  #     setjmp/longjmp the destructor would not run. See docs/adr/0134 and
  #     build_config.rb's wio section for why that configuration is required.
  # Nothing may escape the destructor (std::terminate during unwinding), so the
  # ensure body runs under mrb_protect_error, which also pops the callinfo stack
  # back (vm.c MRB_CATCH arm) and restores the GC arena. Registers live before
  # the guard were allocated below that arena index, so they stay protected.
  # MRB_THROW needs mruby/throw.h, which <mruby.h> does not include.
  puts '#include <mruby/throw.h>'
  # std::uncaught_exceptions(): the guard's "is an unwind in flight" test (see
  # the guard).
  puts '#include <exception>'
  puts <<~'ENSURE_GUARD'
    template <class F>
    struct bc2cpp_ensure_guard {
      mrb_state* M;
      F fn;
      mrb_int depth = M->c->ci - M->c->cibase;
      ~bc2cpp_ensure_guard() noexcept(false) {
        struct RObject* saved = M->exc;
        M->exc = NULL;
        /* OP_EXCEPT's `$!`. The frame depth is the guard's own: a C++ unwind
           has not popped the raiser's callinfo yet. */
        if (saved && saved->tt == MRB_TT_EXCEPTION) {
          M->errinfo = saved;
          M->errinfo_ci_depth = depth;
        }
        /* M->exc is itself a GC root (src/gc.c's own mrb_gc_mark of it in
           both mark phases). Clearing it just above therefore removed the
           ONLY root keeping the in-flight exception alive -- the object
           may long since have been dropped from the GC arena by the
           ordinary mrb_gc_arena_restore every VM send already does. The
           ensure body allocates and so can trigger a real GC, which would
           then collect the very exception this guard is about to put
           back. Re-root it in the arena for the duration, BELOW the index
           mrb_protect_error saves and restores internally, so its own
           restore cannot drop this entry either.

           Found by the differential test, not by reading: it shows up
           only once enough allocation has happened to make a GC actually
           fire inside the ensure body, which is exactly the kind of
           silent, load-dependent corruption a wrong `ensure` translation
           produces. */
        int bc2cpp_ai = mrb_gc_arena_save(M);
        if (saved) mrb_gc_protect(M, mrb_obj_value(saved));
        mrb_bool err = FALSE;
        mrb_value raised = mrb_protect_error(M, [](mrb_state* m, void* ud) -> mrb_value {
          (*(F*)ud)();
          return mrb_nil_value();
        }, (void*)&fn, &err);
        if (!err) {
          /* Restore the real root FIRST, then drop our arena entry. */
          M->exc = saved;
          mrb_gc_arena_restore(M, bc2cpp_ai);
          return;
        }
        /* The ensure body itself raised. Real Ruby semantics: that
           exception SUPERSEDES whatever was already propagating. */
        M->exc = mrb_obj_ptr(raised);
        mrb_gc_arena_restore(M, bc2cpp_ai);
        if (std::uncaught_exceptions() == 0 && M->jmp != NULL) {
          /* Nothing was unwinding yet (normal or `return` exit), so
             nothing will carry this exception outward unless we start
             the unwind ourselves. Throwing here is safe for exactly
             that reason -- hence noexcept(false).

             The test is std::uncaught_exceptions(), NOT "was M->exc
             set": this file's OWN bc2cpp_block_break/
             bc2cpp_method_return unwind the C++ stack while M->exc
             stays NULL, so keying off M->exc would throw straight into
             an in-flight exception and std::terminate -- the classic
             throwing-destructor hazard, and a real one here rather than
             a hypothetical, since those two types cross exactly these
             frames. */
          MRB_THROW(M->jmp);
        }
        /* Otherwise an unwind is already in progress and simply
           continues, now carrying the superseding exception in M->exc. */
      }
    };
  ENSURE_GUARD
  # RESCUE_ERRINFO: OP_EXCEPT's `$!` (mrb->errinfo) for a compiled rescue, and cipop's
  # scoping of it for a compiled function. A direct `_impl` call pushes no callinfo, so
  # the scope object stands in for the frame pop that would clear it.
  puts <<~'ERRINFO'
    static inline void bc2cpp_set_errinfo(mrb_state* M, mrb_value exc) {
      if (mrb_type(exc) == MRB_TT_EXCEPTION) {
        M->errinfo = mrb_obj_ptr(exc);
        M->errinfo_ci_depth = M->c->ci - M->c->cibase;
      }
    }
    struct Bc2cppErrinfoScope {
      mrb_state* M;
      struct RObject* prev;
      mrb_int prev_depth;
      explicit Bc2cppErrinfoScope(mrb_state* m) : M(m), prev(m->errinfo), prev_depth(m->errinfo_ci_depth) {}
      ~Bc2cppErrinfoScope() {
        if (M->errinfo != prev || M->errinfo_ci_depth != prev_depth) M->errinfo = NULL;
      }
      Bc2cppErrinfoScope(const Bc2cppErrinfoScope&) = delete;
      Bc2cppErrinfoScope& operator=(const Bc2cppErrinfoScope&) = delete;
    };
  ERRINFO
  # GETIDX's String arm calls mrb_str_aref (src/string.c, non-static), declared
  # only in mruby/internal.h, which has no C-linkage guard; including it would
  # give it C++ linkage and fail to link. So it is declared `extern "C"` here
  # with internal.h's signature.
  puts 'extern "C" mrb_value mrb_str_aref(mrb_state*, mrb_value, mrb_value, mrb_value);'
  # INTEGER_LSHIFT's kernel: exported by numeric.c but declared in no public header.
  puts 'extern "C" mrb_bool mrb_num_shift(mrb_state*, mrb_int, mrb_int, mrb_int*);'
  # DIV_FASTPATH_SUPPORT: same internal.h situation as mrb_str_aref.
  puts 'extern "C" mrb_value mrb_div_int_value(mrb_state*, mrb_int, mrb_int);'
  # LOADL_BIGINT: same internal.h situation; only where mruby-bigint is built.
  puts '#ifdef MRB_USE_BIGINT'
  puts 'extern "C" mrb_value mrb_bint_new_str(mrb_state*, const char*, mrb_int, mrb_int);'
  puts '#endif'
  # ZSUPER_NATIVE_SUPPORT: same internal.h situation (see ZSUPER_NATIVE_TARGETS).
  # Declared as internal.h does, `mrb_noreturn` included, so g++ treats the
  # following RETURN as unreachable.
  puts 'extern "C" mrb_noreturn void mrb_method_missing(mrb_state*, mrb_sym, mrb_value, mrb_value);'
  # PROFILER_SECTION_SUPPORT: emit_profiler_section_inline calls the native
  # profiling primitives directly (profiler_section_begin/_end, frame_begin/
  # _end) instead of building an RProc for RGSS::Profiler.section/frame and
  # dispatching mrb_funcall_with_block to them. Those primitives are this
  # project's own public C++ API, declared in include/profiler.hxx -- which
  # deliberately does not include <mruby.h>, so it can be pulled in here without
  # pulling mruby twice. The include is emitted ONLY when some compiled body
  # actually inlined a section/frame, so a gem with no such site (every non-rpg2k
  # gem) keeps byte-identical output and pays nothing.
  if compiled.any? { |m| m[:code].include?('profiler_section_begin()') ||
                          m[:code].include?('profiler_frame_begin()') }
    puts '#include "profiler.hxx"'
  end
  # OTHER_DECLS_HEADER: other gems' *_decls.h paths to #include, so calls to
  # OTHER_OWNERS targets are declared.
  if ENV['OTHER_DECLS_HEADER']
    Shellwords.split(ENV['OTHER_DECLS_HEADER']).each { |path| puts "#include \"#{path}\"" }
  end
  puts ''
  print gen.emit_structs
  print gen.emit_ary_entry_helper(compiled)
  print gen.emit_bool_check_helper(compiled)
  print gen.emit_native_core_helpers(compiled)
  print gen.emit_numeric_proof_helpers(compiled)
  print gen.emit_const_lookup_helper
  print gen.emit_native_construct_decls
  print gen.emit_direct_construct_decls
  print gen.emit_forward_decls(compiled)
  print gen.emit_resumable_helpers(compiled)
  print gen.emit_instance_tt_setup(compiled)
  print gen.emit_core_guard_helpers(compiled)
  # OUTLINED_INDEX_OPS: built before the owner-class slots are numbered and printed (INDEX_CLOSED, ADR 0365).
  gen.prepare_index_helpers(compiled)
  gen.reserve_poly_table_slots(compiled)
  print gen.emit_owner_class_cache
  print gen.emit_owner_registrations(compiled, (BC2CPP_WIRED_EMBEDDINGS + BC2CPP_CORE_OWNERS).uniq)
  print gen.emit_hot_only_registration_stubs(compiled, only_owners: only_owners)
  # SYMBOL_CACHE: rewrite every function first, so the table is complete before
  # it is printed ahead of the code that uses it.
  symbol_table = SymbolCache::Table.new
  # GUARD_VIOLATION (ADR 0290): name the method a violation site sits in.
  compiled.each do |m|
    m[:code] = m[:code].gsub('@@SITE@@') { "#{m[:owner]}##{m[:name]}".gsub(/["\\]/) { |c| "\\#{c}" } }
  end
  compiled.each { |m| m[:code] = SymbolCache.rewrite(m[:code], symbol_table) }
  if closed_world
    kept = Hash.new(0)
    compiled.each { |m| m[:code].scan(%r{/\* CLOSED_WORLD kept: (\w+) \*/}) { |(r)| kept[r] += 1 } }
    converted = compiled.sum { |m| m[:code].scan(/\bbc2cpp_nomethod\(M,/).size }
    dropped = compiled.sum { |m| m[:code].scan(%r{^\s*// CLOSED_WORLD_SELF :}).size }
    warn "== closed world fallbacks: #{dropped} guards dropped, #{converted} bc2cpp_nomethod, " \
         "#{kept.values.sum} kept dispatching =="
    # GUARD_VIOLATION (ADR 0290): else arms of guards on a stable class constant, by family.
    violation_families = Hash.new(0)
    compiled.each { |m| m[:code].scan(/"[^"\n]* \((NEW_IDENTITY|CLASS_ARGUMENT|CLASS_EQQ|CLASS_NARROWING|COMPUTED_SEND|CORE_BODY_EXACT|CHECKED_POOL_EXACT)\)"/) { |(f)| violation_families[f] += 1 } }
    warn "== closed world guard violations: #{violation_families.values.sum} bc2cpp_guard_violation =="
    violation_families.sort.each { |f, n| warn "  GUARD_VIOLATION #{f}: #{n}" }
    NomethodReviewed.violation_sites(compiled).uniq.sort.each { |k| warn "  GUARD_VIOLATION_SITE #{k}" }
    kept.sort_by { |r, n| [-n, r] }.each { |r, n| warn "  KEPT #{r}: #{n}" }
    warn ''
    # NIL_RECEIVER (ADR 0296): nil arms of receivers proven nil-or-one-class.
    nil_sites = NomethodReviewed.nil_receiver_sites(compiled)
    warn "== closed world nil receivers: #{nil_sites.size} bc2cpp_nil_receiver =="
    warn "  NILABLE_RECEIVER sites: #{compiled.sum { |m| m[:code].scan(%r{^\s*// NILABLE_RECEIVER :}).size }}"
    nil_sites.uniq.sort.each { |k| warn "  NIL_RECEIVER_SITE #{k}" }
    warn ''
    # NOMETHOD_REVIEWED (docs/adr/0226): a dead fallback nobody reviewed fails
    # the gem build here, not in a later check.
    nomethod_sites = NomethodReviewed.sites(compiled)
    warn "== closed world nomethod sites: #{nomethod_sites.size} =="
    nomethod_sites.each { |s| warn "  NOMETHOD #{s[:key]}#{' [self]' if s[:self_receiver]}" }
    warn ''
    violations = NomethodReviewed.violations(nomethod_sites, compiled, stale: !ENV['BC2CPP_HOT_METHODS'])
    unless violations.empty?
      msg = "bc2cpp: #{violations.size} closed-world NOMETHOD_REVIEWED violation(s) (docs/adr/0226):\n  " \
            "#{violations.join("\n  ")}\n" \
            'Read each site: fix a real missing method, or list a reviewed dead branch in ' \
            'tools/bc2cpp/nomethod_reviewed.rb (scripts/bc2cpp_nomethod_reviewed_update.rb).'
      abort msg unless ENV[NomethodReviewed::ALLOW_ENV] == 'allow'

      warn msg.sub('bc2cpp:', "bc2cpp: #{NomethodReviewed::ALLOW_ENV}=allow, ignoring")
    end
    # PROVEN_MISS_REVIEWED (docs/adr/0275): a send to a proven class that nothing answers.
    miss_sites = ProvenMiss.sites(compiled)
    warn "== closed world proven-class miss sites: #{miss_sites.size} =="
    miss_sites.each { |s| warn "  PROVEN_MISS #{s[:key]}" }
    warn ''
    miss_violations = ProvenMiss.violations(miss_sites, compiled, stale: !ENV['BC2CPP_HOT_METHODS'])
    unless miss_violations.empty?
      msg = "bc2cpp: #{miss_violations.size} closed-world PROVEN_MISS_REVIEWED violation(s) (docs/adr/0275):\n  " \
            "#{miss_violations.join("\n  ")}\n" \
            'Read each site: fix the missing method, or list defensive code in ' \
            'tools/bc2cpp/proven_miss_reviewed.rb (scripts/bc2cpp_proven_miss_update.rb).'
      abort msg unless ENV[NomethodReviewed::ALLOW_ENV] == 'allow'

      warn msg.sub('bc2cpp:', "bc2cpp: #{NomethodReviewed::ALLOW_ENV}=allow, ignoring")
    end
  end
  const_site_cache_code = SymbolCache.rewrite(gen.emit_const_site_cache, symbol_table)
  # OUTLINED_INDEX_OPS: after the symbol cache (their fallbacks become
  # bc2cpp_send too), ahead of every function that calls them.
  index_helpers_code = SymbolCache.rewrite(gen.emit_index_helpers(compiled), symbol_table)
  # NUMERIC_SLOW_PATH (ADR 0292): the by-name calls of the numeric arms' else live here once per helper.
  numeric_slow_code = SymbolCache.rewrite(gen.emit_numeric_slow_helpers(compiled), symbol_table)
  warn "== numeric slow-path helpers: #{gen.numeric_slow_site_counts(compiled).map { |k, n| "#{k} #{n}" }.join(', ').then { |s| s.empty? ? 'none' : s }} sites =="
  warn ''
  warn "== outlined index ops: #{gen.index_helper_site_counts(compiled).map { |k, n| "#{k} #{n}" }.join(', ')} sites =="
  warn "== index helpers closed (INDEX_CLOSED, ADR 0365): #{gen.index_closed_summary(compiled)} =="
  warn ''
  eqq_helper_code = SymbolCache.rewrite(gen.emit_eqq_helper(compiled), symbol_table)
  warn "== shared === helper (EQQ_DIRECT): #{gen.eqq_helper_site_count(compiled)} sites =="
  warn ''
  poly_table_sites = gen.poly_table_site_counts(compiled)
  warn "== poly table dispatch: #{poly_table_sites.map { |t, n| "#{t} #{n}" }.join(', ').then { |s| s.empty? ? 'none' : s }} sites =="
  warn ''
  print SymbolCache.emit(symbol_table)
  print const_site_cache_code
  print index_helpers_code
  print eqq_helper_code
  print numeric_slow_code
  print gen.emit_poly_tables(compiled)
  compiled.each { |m| print m[:code] }

  # This run's cross-TU declarations header, for other gems'
  # OTHER_DECLS_HEADER (see emit_decls_header). Always written.
  File.write(File.join(out_dir, "#{symbol}_decls.h"), gen.emit_decls_header(compiled))
  profile_phase.call('C++ emission + symbol rewrite')

  warn ''
  warn '== compiled entry points =='
  compiled.each do |m|
    # A hand-written registration via plain mrb_define_method would make a
    # private/protected method public, so the listing flags visibility.
    vis =
      case m[:visibility]
      when :public then ''
      when :private then '  [private -- use mrb_define_private_method, not mrb_define_method]'
      when :protected then '  [protected -- mruby has no mrb_define_protected_method; ' \
                            'registering this with mrb_define_method makes it public, a real behavior change]'
      end
    # A ".singleton" owner (`def self.x` / `class << self`) must be registered with
    # mrb_define_class_method (onto the singleton class), not mrb_define_method.
    # Such entries are always :public (singleton privacy is not modelled), so the
    # note is appended independently of `vis`.
    singleton_note = m[:owner].end_with?('.singleton') ? '  [class method -- use mrb_define_class_method, ' \
                                                          'not mrb_define_method]' : ''
    warn "  #{m[:entry]} / #{m[:impl]}  (#{m[:owner]}##{m[:name]}, arity #{m[:arity]})#{vis}#{singleton_note}"
  end

  # CORE_DEFS (ADR 0264): which of those bodies come from mruby's own Ruby, for the
  # coverage report's engine/core split.
  core_entries = compiled.select { |m| m[:label] && CoreDefs.core_source?(ireps[m[:label]]&.file) }
  warn ''
  warn "== core-source compiled entry points (#{core_entries.size}) =="
  core_entries.each { |m| warn "  #{m[:owner]}##{m[:name]}" }

  # YIELD_REACH (ADR 0283): what the yield-free proof gave this build.
  yf = gen.yield_free_report(compiled.filter_map { |m| m[:label] })
  warn ''
  warn '== yield-free proof (YIELD_REACH) =='
  warn "  world: #{yf[:sound] ? 'closed, proof in force' : 'not a closed world, nothing is proved yield-free'}" \
       "#{yf[:seal] == true ? '' : " (Enumerator machinery not sealed: #{yf[:seal].inspect})"}"
  warn "  compiled methods: #{yf[:methods]}: #{yf[:methods_free]} yield-free, #{yf[:methods] - yf[:methods_free]} may yield " \
       "(#{yf[:methods_body_free]} have a body that cannot suspend a Fiber given a yield-free block)"
  warn "  compiled blocks with a direct entry: #{yf[:blocks]}: #{yf[:blocks_free]} yield-free, #{yf[:blocks] - yf[:blocks_free]} may yield"
  warn "  block-taking core methods with a run-time guard: #{yf[:guarded_core]}, #{yf[:guarded_core_relaxable]} stay compiled under a " \
       'Fiber when the block is yield-free'
  warn "  BLOCK_CORE_DIRECT sites: #{yf[:arm_sites]}, #{yf[:arm_sites_free]} with a yield-free block; " \
       "arms: #{yf[:arms]}, #{yf[:arms_unguarded]} with the root-context test dropped"
  warn "  methods refused as crossable under a Fiber (FIBER_REACHABILITY_UNSAFE): #{yf[:unsafe_methods]}"

  warn ''
  warn '== classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) =='
  gen.embedding_classes.each { |k| warn "  #{k}" }

  # Step 6h's diagnostic: compiled entry points whose name is never a bytecode
  # call target (collect_static_call_target_names) nor a literal mrb_funcall
  # name in NATIVE_SRCS (extract_native_call_names): deletion candidates, not
  # proof. RGSS classes are the public API of per-game scripts this tool cannot
  # see (docs/rpgxp-rgss-api-gap.md), so names there are expected;
  # mruby-rpg2k/mruby-lcf have no external script layer, so their names are
  # stronger evidence.
  static_call_names = collect_static_call_target_names(ireps)
  native_call_names = ENV['NATIVE_SRCS'] ? extract_native_call_names(native_paths) : Set.new
  # Methods mruby's C core calls through a `mrb_sym mid = MRB_SYM(...)` local
  # rather than a literal, invisible to extract_native_call_names' forward
  # lookahead, each with a verified call site in 3rd/mruby/src: initialize /
  # initialize_copy (class.c), method_missing / respond_to_missing? (vm.c,
  # kernel.c, class.c), to_s / inspect (kernel.c, array.c), == / eql? / <=> /
  # hash (object.c, array.c, kernel.c, numeric.c, hash.c), call (hash.c default
  # proc). coerce/each/to_ary/to_str/to_int/to_hash/[] were checked and are not
  # called this way in this core.
  always_reachable = %w[
    initialize initialize_copy
    method_missing respond_to_missing?
    to_s inspect
    == eql? <=> hash
    call
  ].to_set
  reachable_names = static_call_names | native_call_names | always_reachable
  never_called = compiled.reject { |m| reachable_names.include?(m[:name]) }
  warn ''
  warn "== never called (#{never_called.size} of #{compiled.size} compiled entry points -- " \
       "zero evidence in this program's own bytecode or NATIVE_SRCS; see Step 6h's own comment) =="
  if never_called.empty?
    warn '  (none)'
  else
    never_called.each { |m| warn "  #{m[:owner]}##{m[:name]}" }
  end
  gen.write_native_setter_report(ENV.fetch('BC2CPP_NATIVE_SETTER_REPORT')) if ENV['BC2CPP_NATIVE_SETTER_REPORT']
  profile_phase.call('diagnostics + sidecar writes')
end
