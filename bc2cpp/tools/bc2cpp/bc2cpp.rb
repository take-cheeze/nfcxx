#!/usr/bin/env ruby
# frozen_string_literal: true

# A small mruby bytecode -> C++ AOT compiler.
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
# symbols, lv, instructions) from it.

require 'shellwords'
require 'set'
require 'fileutils'
require_relative 'type_check_variants'
type_check_variants = TypeCheckVariants.parse_argv(ARGV) if $PROGRAM_NAME == __FILE__
TypeCheckVariants.arm_guard if type_check_variants
require_relative 'compact_output'
require_relative 'shared_generation'
require_relative 'embed_init_guard'
require_relative 'inframe_placement'

# Parts split out by scripts/bc2cpp/split.rb, loaded in original definition order.
require_relative 'irep'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_constants'
require_relative 'register_flow'
require_relative 'registry'
require_relative 'native_return_classes'
require_relative 'lint_crosscheck'
require_relative 'native_names'
require_relative 'native_ivar_scopes'
require_relative 'outside_ruby_ivar_scopes'

require_relative 'native_expression_devirt'
require_relative 'branch_hints'
require_relative 'tagged_fixnum'
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
require_relative 'strict_hints'
require_relative 'predicate_returns'
require_relative 'conversion_returns'
require_relative 'core_methods'
require_relative 'core_fact_sigs'
require_relative 'enumerator_model'

require_relative 'integer_constants'
require_relative 'integer_constant_ranges'
require_relative 'native_construct_schema'
require_relative 'dynamic_names'
require_relative 'ivar_layout'
require_relative 'annotations'
require_relative 'rbs_signatures'
require_relative 'declared_returns'
require_relative 'declared_constants'
require_relative 'rbs_param_check'
require_relative 'class_layout'
require_relative 'element_layouts'
require_relative 'record_hash'
require_relative 'rbs_record_types'
require_relative 'diagnostics'
require_relative 'dispatch_targets'
require_relative 'irep_arity'
require_relative 'codegen'
require_relative 'codegen_ivar_poly'
require_relative 'codegen_native_send'
require_relative 'codegen_exact_receiver'
require_relative 'codegen_outside_owner_call'
require_relative 'codegen_static_owner_arms'
require_relative 'codegen_owner_set_direct'
require_relative 'codegen_native_direct'
require_relative 'codegen_native_exact_direct'
require_relative 'codegen_native_singleton'
require_relative 'codegen_exact_native_wrappers'
require_relative 'codegen_native_core_direct'
require_relative 'codegen_native_owner_map'
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
require_relative 'codegen_array_new_inline'
require_relative 'codegen_fixnum_proof'
require_relative 'codegen_numeric_proof'
require_relative 'codegen_numeric_args'
require_relative 'codegen_param_fold'
require_relative 'codegen_numeric_ivars'
require_relative 'ivar_slot_assured'
require_relative 'ivar_slot_assured_args'
require_relative 'codegen_numeric_returns'
require_relative 'codegen_class_pools'
require_relative 'codegen_entry_specialize'
require_relative 'codegen_constructor_pools'
require_relative 'codegen_entry_seeds'
require_relative 'codegen_class_object_args'
require_relative 'codegen_return_classes'
require_relative 'codegen_block_returns'
require_relative 'codegen_core_ruby_results'
require_relative 'codegen_return_accessors'
require_relative 'codegen_exact_core_arms'
require_relative 'codegen_captured_locals'
require_relative 'codegen_block_self'
require_relative 'block_self_world'
require_relative 'codegen_native_results'
require_relative 'codegen_instance_receivers'
require_relative 'codegen_class_narrowing'
require_relative 'codegen_freeze_fold'
require_relative 'codegen_decided_branch'
require_relative 'codegen_arm_prune'
require_relative 'codegen_call_facts'
require_relative 'codegen_nilable_receiver'
require_relative 'codegen_setter_pools'
require_relative 'codegen_self_new'
require_relative 'codegen_overloaded_construct'
require_relative 'codegen_checked_send'
require_relative 'lexical_consts'
require_relative 'codegen_numeric_consts'
require_relative 'codegen_numeric_slow'
require_relative 'codegen_numeric_slow_zero'
require_relative 'codegen_index_closed'
require_relative 'codegen_integer_tag_else'
require_relative 'codegen_collection_ops'
require_relative 'codegen_numeric_roots'
require_relative 'codegen_native_int_args'
require_relative 'codegen_native_param_unbox'
require_relative 'codegen_fixnum_ranges'
require_relative 'codegen_tuple_returns'
require_relative 'codegen_return_analysis'
require_relative 'codegen_loop_inline'
require_relative 'codegen_step_loop'
require_relative 'codegen_kernel_loop'
require_relative 'codegen_resumable'
require_relative 'codegen_block_fallback'
require_relative 'codegen_yield_free'
require_relative 'codegen_runtime_def'
require_relative 'codegen_insn'
require_relative 'codegen_sealed_int16'
require_relative 'codegen_keyword_send'
require_relative 'codegen_send'
require_relative 'codegen_eqq'
require_relative 'codegen_constant_object'
require_relative 'codegen_unlisted_class_call'
require_relative 'codegen_arg_shapes'
require_relative 'codegen_computed_send'
require_relative 'codegen_block_core_direct'
require_relative 'codegen_collect_direct'
require_relative 'codegen_transpose_direct'
require_relative 'codegen_integer_bit_aref'
require_relative 'codegen_array_hash'
require_relative 'codegen_guarded_block_inline'
require_relative 'codegen_core_exact_direct'
require_relative 'codegen_core_self_native'
require_relative 'codegen_entry_header'
require_relative 'codegen_core_compiled_cmp'
require_relative 'codegen_interface_tables'
require_relative 'codegen_subtree_dispatch'
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
require_relative 'provable_error_report' if ENV['BC2CPP_PROVABLE_ERROR_REPORT']
require_relative 'element_site_report' if ENV['BC2CPP_ELEMENT_REPORT']
require_relative 'receiver_proof_report' if ENV['BC2CPP_RECEIVER_PROOF_REPORT']
# Last: its compile_method and compile_insn prepends must be outermost.
require_relative 'codegen_stack_tuples'

if $PROGRAM_NAME == __FILE__
  InFramePlacement.refuse_if_requested!
  # --annotated keeps the generated C++'s `//` proof and dispatch comments (the checks that read them pass it);
  # without it they are stripped from stdout, the only default.
  annotated = !ARGV.delete(ANNOTATED_FLAG).nil?
  type_check_only = ENV['BC2CPP_TYPE_CHECK_ONLY'] == '1'
  abort 'bc2cpp: --type-check-variants requires report-only mode' if type_check_variants && !type_check_only
  if type_check_only && ENV['BC2CPP_TYPE_FACTS'].to_s.empty?
    abort 'bc2cpp: BC2CPP_TYPE_CHECK_ONLY requires BC2CPP_TYPE_FACTS'
  end
  # SHARED_GENERATION: `--units PLAN` runs the analysis once and forks one generation per unit.
  shared_units, srcs = SharedGeneration.parse_argv(ARGV)
  abort 'bc2cpp: BC2CPP_TYPE_CHECK_ONLY cannot emit shared units' if type_check_only && shared_units
  abort 'bc2cpp: cannot combine --units and --type-check-variants' if shared_units && type_check_variants
  if srcs.empty?
    raise "usage: bc2cpp.rb [#{ANNOTATED_FLAG}] [#{SharedGeneration::FLAG} PLAN] file1.rb [file2.rb ...]  " \
          '(env: MRBC, OUT_SYMBOL, OUT_DIR, ONLY_OWNERS)'
  end
  # Closed world only: checked before any work.
  missing_inputs = %w[BC2CPP_BUILD_NAME BC2CPP_BUILD_GEMS NATIVE_SRCS FOREIGN_RUBY_SRCS].reject { |key| ENV[key] }
  unless missing_inputs.empty?
    abort "bc2cpp: missing #{missing_inputs.join(', ')}: bc2cpp compiles closed-world programs only " \
          '(docs/adr/0466) and needs the build name, its gem list and every outside native and Ruby source'
  end

  shared_prefix, shared_stderr = SharedGeneration.start(shared_units) if shared_units
  symbol = ENV['OUT_SYMBOL'] || File.basename(srcs.first, '.rb').gsub(/[^a-zA-Z0-9_]/, '_')
  out_dir = ENV['OUT_DIR'] || File.dirname(srcs.first)
  SharedGeneration.arm_guard if shared_units
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

  # PREDICATE_RETURNS: a method ending in ? must return bool, or be whitelisted; a violation fails the build here.
  PredicateReturns.enforce!(srcs.select { |path| path.end_with?('.rb') })
  # CONVERSION_RETURNS: to_s, to_str, to_int, to_ary and to_hash take only optional positional parameters; their returns
  # are runtime-checked hints, declared in a generated signature file that joins the program's signatures.
  ConversionReturns.enforce!(srcs.select { |path| path.end_with?('.rb') })
  # Mruby's own Ruby defining a native-named method (File#inspect) is hidden from the registry, so it gets no hint.
  conversion_sigs = ConversionReturns.write_sigs(srcs.select { |path| path.end_with?('.rb') && !CoreDefs.core_source?(path) })
  ireps, root_label = compile_ireps(srcs, symbol, out_dir)
  order = dfs_order(ireps, root_label)
  registry, superclass_of, container_constants, included_modules, prepended_modules, unknown_mixins,
    struct_member_lists, class_decls, walked_ireps, module_body_ivar_labels, constant_assignment_sites,
    declared_modules, alias_sites = build_registry(ireps, root_label)
  # ESCAPE_ANALYSIS: callees are every definition of a name, so the registry is copied before
  # the core filtering below drops the methods the build keeps interpreted.
  escape_registry = EscapeAnalysis.enabled? ? registry.transform_values(&:dup) : nil
  # BLOCK_SELF: every bytecode definition of a name, the interpreted core ones the filtering below drops
  # included, since a block handed to one of them runs under whatever self that body chooses.
  CodeGen.block_self_bodies = registry.transform_values { |defs| defs.select(&:irep) }
  # CORE_DEFS: a core-source definition a later one replaces is not the
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
  core_refused = CoreMethods.load_refused(CoreMethods::DEFAULT_PATH)
  core_ineligible = CoreMethods.excluded_labels(registry, ireps, core_refused)
  # An interpreted core replacement still intercepts inherited lookup.
  CodeGen.core_result_opaque_defs = CoreRubyResults.opaque_definitions(registry, core_ineligible, ireps, alias_sites, CodeGen.core_aliases)
  CodeGen.core_result_installed_names = CoreRubyResults.installed_names(ireps)
  # ENUMERATOR_MODEL: read before the core filtering below drops the interpreted Kernel#to_enum.
  CodeGen.enumerator_model = EnumeratorModel.analyze(registry, ireps, alias_sites)
  core_stale_refusals = CoreMethods.stale(registry, ireps, core_refused)
  core_bytecode = registry.values.flatten.count { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
  core_all_defs = registry.values.flatten.select { |d| d.irep && d.core }
  # A core attr_* accessor or module_function copy has no body to compile: it stays the interpreter's.
  registry.each_value { |defs| defs.reject! { |d| d.irep ? core_ineligible.include?(d.irep) : d.core } }
  registry.delete_if { |_, defs| defs.empty? }
  profile_phase.call('mrbc + parse + registry')

  # CLOSED_WORLD: bc2cpp compiles closed-world programs only. A build that loads
  # or defines Ruby at runtime uses the plain mruby build instead. The build's name, its gem list and the
  # outside native and Ruby sources are required inputs (checked above); without them there is no closed world.
  # Constructed before return/element analysis, which uses its method-lookup proof for inherited return classes.
    repo_root = File.expand_path('../..', __dir__)
  build_name = ENV['BC2CPP_BUILD_NAME']
  build_gems = Shellwords.split(ENV['BC2CPP_BUILD_GEMS']).to_h { |kv| kv.split('=', 2) }
    CodeGen.build_gem_names = build_gems.keys.to_set
    errors = bc2cpp_closed_world_violations(build_name, build_gems, repo_root, compiled_srcs: srcs)
  abort "bc2cpp: build '#{build_name}' is not a closed world:\n  #{errors.join("\n  ")}" unless errors.empty?

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

  # DEFINE_METHOD_SITES: the class-body `define_method(:x) { }` candidates the registry
  # collected stay definitions only in a closed world that trusts `define_method` itself.
  define_method_kept, define_method_dropped =
    DefineMethodSites.settle(registry, trusted: closed_world.define_method_sites_trusted?)
  if define_method_kept + define_method_dropped > 0
    warn "== define_method sites (#{define_method_kept} registered as definitions, " \
         "#{define_method_dropped} left as installers) =="
  end
  # ALIAS_SITES: class-body aliases with literal names, as definitions of the new name.
  alias_kept, alias_dropped = AliasSites.settle(registry, ireps, closed: !closed_world.nil?,
                                                          method_trusted: closed_world&.alias_method_trusted? || false)
  if alias_kept + alias_dropped > 0
    warn "== alias sites (#{alias_kept} registered as definitions, #{alias_dropped} left as installers) =="
  end
  # DEFINE_METHOD_LOOPS: a settled loop send names only the methods it was expanded into.
  DynamicNames.settled_sends = DefineMethodSites.loop_sites(registry)

  # NATIVE_SRCS: C/C++ sources to scan for mrb_define_method-family calls (see
  # extract_native_method_names). A required input (CLOSED_WORLD).
    native_paths = Shellwords.split(ENV['NATIVE_SRCS'])
    # NATIVE_OWNER_MAP: every native source, not only those with a literal name registration.
    CodeGen.native_source_paths = native_paths
    # NATIVE_RETURN_CLASSES (option B): empty unless BC2CPP_NATIVE_FN_KINDS names the native function kinds.
    CodeGen.native_return_classes = NativeReturnClasses.table_for_env(native_paths)
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
  # NATIVE_CONSTRUCT_SCHEMA_AUDIT: audit only.
    warn '== native construct schema audit (row vs scraped mrb_get_args) =='
    NATIVE_CONSTRUCT_TARGETS.sort.each do |klass, row|
      verdict, detail = NativeConstructSchema.audit(native_paths, klass, row)
      warn "  #{verdict.to_s.upcase}  #{klass}  (#{detail})"
    end
    warn ''
  profile_phase.call('closed world + native scans')

  # The closed world enumerates callees; a global refusal or a method_missing class leaves the analysis
  # uninstalled and every consumer keeps its earlier gate. Ruby the build interprets (an outside source this
  # run did not compile) may define any name it spells; the compiled core Ruby is in the ireps.
  if escape_registry && closed_world.global_refusal.nil? && closed_world.method_missing_classes.empty?
    escape_aliases = Hash.new { |h, k| h[k] = [] }
    alias_sites.each { |site| escape_aliases[site[:new]] << site[:old] }
    compiled_files = ireps.each_value.to_set(&:file)
    hidden_ruby = foreign_method_owners(outside_ruby.reject { |path| compiled_files.include?(path) })
    hidden_ruby_names = hidden_ruby.names
    warn "== escape analysis: #{ireps.size} ireps, #{hidden_ruby_names.size} method names defined by " \
         "Ruby this run does not compile (#{hidden_ruby.owners.size} owner-scoped) =="
    EscapeAnalysis.install(EscapeAnalysis::World.new(ireps: ireps, defs: escape_registry, aliases: escape_aliases,
                                                     native_names: native_names, native_files: native_name_sources,
                                                     native_owners: CodeGen::NATIVE_OWNER_MAP_CACHE[native_paths] ||=
                                                       NativeOwnerMap.build(native_paths),
                                                     superclass_of: superclass_of, included: included_modules,
                                                     prepended: prepended_modules, unknown_mixins: unknown_mixins,
                                                     modules: declared_modules, struct_classes: struct_member_lists.keys,
                                                     hidden_owners: hidden_ruby,
                                                     invisible: lambda { |name|
                                                       # A name only plain class-body defs make is judged per receiver class (hidden_owners).
                                                       hidden_ruby.global ||
                                                         (hidden_ruby_names.include?(name) && !hidden_ruby.owners.key?(name)) ||
                                                         closed_world.unknown_definer?(name)
                                                     }))
  end

  # CORE_VISIBILITY: a core method is compiled and registered whenever it is
  # eligible, but only one whose name no native method shares (and no fast-path
  # operator, and no guard) is a registry definition, i.e. a dispatch target. Every name-keyed
  # proof and inline path in the compiler models mruby's own method for the names
  # natives define, on the premise that its Ruby definitions cannot be seen; a
  # core definition there would switch them off (FIXNUM_COMPARE, LITERAL ===,
  # ELEM_HINT through `compact`, ...). The others are emitted from CodeGen's
  # `core_hidden_defs`, without becoming candidates.
  # A guarded method is never a direct-call target either, so a
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
  compiled_ruby = ireps.each_value.to_set { |irep| File.expand_path(irep.file.to_s) }
  # Every linked core gem's mrblib too: outside_ruby leaves out the core gems a build compiles, which a world that
  # does not compile them still runs.
  linked_mrblib = build_gems.values.flat_map { |dir| Dir["#{dir}/mrblib/**/*.rb"] }.select { |path| CoreDefs.core_source?(path) }
  unread_ruby = (Shellwords.split(ENV['FOREIGN_RUBY_SRCS']) + outside_ruby + linked_mrblib)
                .map { |path| File.expand_path(path) }.uniq
  unseen_flipped = CoreDefs.add_unseen_placeholders!(
    registry, ireps, core_all_defs, alias_sites,
    foreign_method_names(unread_ruby.reject { |path| compiled_ruby.include?(path) }.sort)
  )
  warn "== Ruby definers outside the registry (#{unseen_flipped.size} flipped a MONO name to POLY) =="
  unseen_flipped.sort.each { |n| warn "  FLIP :#{n}" }
  warn ''

  warn '== whole-program method registry =='
  registry.sort.each do |name, defs|
    mono = defs.size == 1
    owners = defs.map(&:owner).join(', ')
    warn "  #{mono ? 'MONO' : 'POLY'}  :#{name}  (#{defs.size} def#{'s' unless defs.size == 1}: #{owners})"
  end

  # CORE_METHODS: what the core mrblib did to the registry, once. Keyed on the
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
  # RBS_SIGNATURES: signature files feed the same three annotation tables. With no .rbs file nothing
  # here runs and nothing is printed.
  sig_applied = nil
  sig_class_annotations = nil
  sig_element_annotations = nil
  sig_root = ENV['BC2CPP_SIG_ROOT'] || File.expand_path('../..', __dir__)
  sig_dirs = RbsSignatures.dirs_from_env(File.expand_path('../..', __dir__)) + [conversion_sigs].compact
  if (sig_loaded = RbsSignatures.load(sig_dirs, display_root: sig_root))
    sig_owners = registry.values.flatten.map(&:owner).uniq
    sig_class_annotations = ClassAnnotations.extract(ireps, registry, sig_owners)
    sig_element_annotations = ElementAnnotations.extract(ireps, registry, sig_owners)
    sig_comment_class_args = sig_class_annotations.transform_values { |ann| ann.args.dup } # RBS_CHECKED_PARAMS
    sig_applied = RbsSignatures.apply(sig_loaded, ireps, registry, annotations, sig_class_annotations,
                                      sig_element_annotations, class_decls: class_decls)
    # RBS_BLOCK_PARAM_HINT: the declared block types, read by block_fallback_rbs_param_class.
    CodeGen.rbs_block_signatures = sig_applied.ir_block_signatures
    # DECLARED_RETURN_CHECK: return declarations every body is checked against.
    CodeGen.declared_returns = DeclaredReturns.from_signatures(sig_loaded, ireps, registry)
    CodeGen.declared_return_root = sig_root
    # DECLARED_RETURN_GUARD: a runtime-checked declaration (%a{bc2cpp:hint}) is a fact only because its compiled body
    # checks every return, and one no body can carry is an error.
    CodeGen.declared_return_hint_refusals = DeclaredReturns.hint_refusals(sig_loaded, ireps, registry)
    # BLOCK_RETURNS: `[T] ... { ... -> T } -> T` and `{ ... } -> self` declarations, checked with them.
    CodeGen.block_returns = BlockReturns.from_signatures(sig_loaded)
    warn '== signature files (RBS_SIGNATURES) =='
    sig_loaded.files.each { |f| warn "  SIG_FILE #{f}" }
    sig_applied.diagnostics.each { |d| warn "  #{d.file}:#{d.line}:#{d.col}: #{d.severity}: #{d.message} [#{d.code}]" }
    if sig_applied.diagnostics.any? { |d| d.severity == 'error' } && !ENV['BC2CPP_TYPE_FACTS'].to_s.then { |v| !v.empty? }
      abort "\n[bc2cpp] RBS_SIGNATURES: #{sig_applied.diagnostics.count { |d| d.severity == 'error' }} unusable signature(s) (see above)."
    end
  end
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
  # probing pass (ARRAY_RETURN_PROOF needs foreign_methods). NATIVE_SRCS and
  # FOREIGN_RUBY_SRCS are required inputs (CLOSED_WORLD). Diagnostic consumers find
  # sections by header text, not position.
  foreign_ruby_srcs = Shellwords.split(ENV['FOREIGN_RUBY_SRCS'])
  foreign_methods = profile_call.call('foreign_method_names') { foreign_method_names(foreign_ruby_srcs) }
  # BLOCK_SELF: names an outside Ruby source this build does not compile may define (a body it cannot read).
  compiled_files = ireps.each_value.to_set { |irep| File.expand_path(irep.file.to_s) }
  CodeGen.block_self_unread_names =
    foreign_method_names(foreign_ruby_srcs.reject { |path| compiled_files.include?(File.expand_path(path)) })
  # BLOCK_SELF_WORLD: which blocks a rebinder may run under another self, and whether the world lets any
  # other Proc reach a rebinder. Every Ruby source of the closed world is read as bytecode: the outside ones this
  # build does not compile are compiled here for the analysis alone.
  # The Ruby sources this build does not compile, as bytecode. BlockSelfWorld and UniqueClassNames both read them.
  unread = (foreign_ruby_srcs + outside_ruby).map { |path| File.expand_path(path) }.uniq.sort
                                            .reject { |path| compiled_files.include?(path) }
  outside_ireps = {}
  outside_root = nil
  refusal = nil
  unless unread.empty?
    begin
      outside_ireps, outside_root = compile_ireps(unread, "#{symbol}_block_self_world", out_dir)
    rescue StandardError => e
      refusal = "an outside Ruby source does not compile (#{e.message.lines.first&.strip})"
    end
  end
  CodeGen.block_self_world = profile_call.call('BlockSelfWorld.analyze') do
    method_labels = {}
    CodeGen.block_self_bodies.each { |name, defs| defs.each { |d| method_labels[d.irep] = [d.owner, name] } }
    BlockSelfWorld.analyze(ireps: ireps, outside_ireps: outside_ireps, native_paths: (native_paths + outside_native).uniq,
                           method_labels: method_labels, superclass_of: superclass_of, root: repo_root, refusal: refusal)
  end
  closed_world.block_self_world = CodeGen.block_self_world
  warn "== block self world (ADR 0477): #{CodeGen.block_self_world.holds? ? 'holds' : "may rebind: #{CodeGen.block_self_world.why}"}; " \
       "#{CodeGen.block_self_world.sites.size} literal rebinder site(s), #{CodeGen.block_self_world.rebound.size} rebound block(s) =="
  CodeGen.block_self_world.failures.drop(1).each { |why| warn "  also: #{why}" }
  # UNIQUE_CLASS_NAME: set before RBS_CHECKED_PARAMS and the first ClassLayout pass, since every
  # trace_new_target caller reads it (and ClosedWorld#stable_constant_identity?, which BLOCK_RETURNS needs).
  UniqueClassNames.table = profile_call.call('UniqueClassNames.analyze') do
    UniqueClassNames.analyze(ireps, root_label, native_paths, foreign_ruby_srcs,
                             superclass_of: superclass_of, included: included_modules,
                             prepended: prepended_modules, unknown_mixins: unknown_mixins,
                             ruby_sources: refusal ? nil : { ireps: outside_ireps, root: outside_root })
  end
  UniqueClassNames.object_mixins = Array(included_modules['Object'])
  if (dump = ENV['BC2CPP_LEXICAL_DUMP']) # for scripts/bc2cpp checks of the constant lookup: the facts as JSON
    require 'json'
    facts = UniqueClassNames.lexical&.transform_values { |v| v.is_a?(Set) ? v.to_a : v }
    File.write(dump, JSON.generate(table: UniqueClassNames.table, lexical: facts, object_mixins: UniqueClassNames.object_mixins))
  end
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

  # RBS_CHECKED_PARAMS: a class parameter type is kept only when every caller is proven to pass it.
  if sig_applied
    param_outside = RbsParamCheck.outside_call_names(native_paths, foreign_ruby_srcs, ireps.values.to_set(&:file))
    # The `new` / `super` sites of each initialize, from a CodeGen built only that far.
    param_constructors = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new,
                                     foreign_methods, outside_world_tokens(native_paths + foreign_ruby_srcs),
                                     native_name_sources, included_modules, prepended_modules, unknown_mixins,
                                     analysis_only: :constructor_sites, closed_world: closed_world,
                                     outside_ivar_names: outside_ivar_names(native_paths + foreign_ruby_srcs))
    param_diags, = RbsParamCheck.check(sig_loaded, ireps, registry, sig_class_annotations,
                                       comment_class_args: sig_comment_class_args, call_sites: call_sites,
                                       outside_names: param_outside, constructor_entries: param_constructors,
                                       superclass_of: superclass_of, display_root: sig_root, applied: sig_applied,
                                       declared_returns: CodeGen.declared_returns)
    sig_applied.diagnostics.concat(param_diags)
    param_diags.each { |d| warn "  #{d.file}:#{d.line}:#{d.col}: #{d.severity}: #{d.message} [#{d.code}]" }
    if param_diags.any? { |d| d.severity == 'error' } && ENV['BC2CPP_TYPE_FACTS'].to_s.empty?
      abort "\n[bc2cpp] RBS_CHECKED_PARAMS: #{param_diags.size} unproven parameter type(s) (see above)."
    end
  end

  # CLOSED_WORLD_VALUE_CONSTANT: a single class-constructor assignment is a
  # guarded receiver hint, not an unconditional claim about the constant value.
  inferred_constant_classes = profile_call.call('single-assignment value constants') do
    infer_constructed_constant_classes(ireps, constant_assignment_sites, registry, container_constants, closed_world,
                                       native_name_sources: native_name_sources, included_modules: included_modules,
                                       prepended_modules: prepended_modules, unknown_mixins: unknown_mixins,
                                       class_decls: class_decls)
  end
  container_constants.merge!(inferred_constant_classes)
  warn "== single-assignment constructed constants (CLOSED_WORLD_VALUE_CONSTANT): #{inferred_constant_classes.size} =="
  inferred_constant_classes.sort.each { |name, klass| warn "  CONST_CLASS  #{name}  (#{klass})" }

  # The operator precondition both integer proofs share (IntegerConstantRanges.integer_ops_safe?): no Ruby
  # Integer#+ - * / == anywhere in the program.
  operators_safe = IntegerConstantRanges.integer_ops_safe?(registry, included_modules, prepended_modules, unknown_mixins)
  # INTEGER_CONSTANT_PROOF: a proven name lets GETCONST feed an unchecked mrb_fixnum, so the proof holds
  # only where the closed world shows every constant binding static, and its poison scan covers the closed world's
  # outside sources (the target's host, every linked gem) as well as NATIVE_SRCS and FOREIGN_RUBY_SRCS.
  # BYTECODE_CONSTANT_FACTS: the class, value and Fixnum interval of every constant binding, derived on the
  # bytecode IR. It decides the constant sets below: the Fixnum-admitted names, the folded values and the intervals.
  freeze_safe = DeclaredConstants.stock_method?('freeze', 'Integer', registry, included_modules, prepended_modules,
                                                unknown_mixins)
  # Frozen literal containers: a stock Array, Hash or String freeze answers its receiver too.
  freeze_classes = %w[Array Hash String].select do |klass|
    DeclaredConstants.stock_method?('freeze', klass, registry, included_modules, prepended_modules, unknown_mixins)
  end.to_set
  constant_facts = profile_call.call('BytecodeIR::ConstantFacts.analyze') do
    BytecodeIR::ConstantFacts.analyze(
      ireps, sites: constant_assignment_sites,
             poisoned: IntegerConstants.native_defined_const_names((native_paths + outside_native).uniq) |
                       IntegerConstants.foreign_const_names((foreign_ruby_srcs + outside_ruby).uniq),
             operators_safe: operators_safe, freeze_safe: freeze_safe, freeze_classes: freeze_classes.map(&:to_sym).to_set
    )
  end
  # Report only (CLASS_INTEGER_PROOF): the class rows get their own run, whose poison leaves out the foreign literal
  # definitions and the bit-operator definitions the IR already binds (IntegerConstants.foreign_class_poison). The value
  # run above keeps foreign_const_names, so codegen reads only what it read before.
  ir_paths = ireps.each_value.filter_map { |irep| irep.file && File.expand_path(irep.file) }.to_set
  # HASH_LOOKUP (report only, class run): Hash#[] must be stock, no non-core native `[]` on a Hash ancestor (an
  # unresolved owner refuses, as CallFacts reads owners), and no instance singleton (the merge proof's gate). Integer
  # keys need no eql?/hash proof: mruby hashes and compares a fixnum key without dispatch (3rd/mruby/src/hash.c).
  hash_ancestors = CoreHierarchySigs.ancestors('Hash')
  aref_regs, aref_opaque = NativeExpressionDevirt.class_registrations(native_name_sources.values.flatten.uniq)
  aref_owners = aref_regs.to_h.fetch('[]', []).reject { |e| e[:path].match?(ClosedWorld::NATIVE_CORE) }
                         .map { |e| e[:owner]&.fetch(:class_name, nil) } + aref_opaque.to_h.fetch('[]', [])
  hash_lookup_safe = DeclaredConstants.stock_method?('[]', 'Hash', registry, included_modules, prepended_modules,
                                                    unknown_mixins) &&
                     aref_owners.none? { |owner| owner.nil? || hash_ancestors.include?(owner) } &&
                     closed_world.exact_instances_singleton_free?
  class_facts = profile_call.call('BytecodeIR::ConstantFacts.analyze (class)') do
    BytecodeIR::ConstantFacts.analyze(
      ireps, sites: constant_assignment_sites,
             poisoned: IntegerConstants.native_defined_const_names((native_paths + outside_native).uniq) |
                       IntegerConstants.foreign_class_poison((foreign_ruby_srcs + outside_ruby).uniq, ir_paths),
             operators_safe: operators_safe, freeze_safe: freeze_safe, freeze_classes: freeze_classes.map(&:to_sym).to_set,
             hash_lookup_safe: hash_lookup_safe,
             lookup_poisoned: IntegerConstants.native_defined_const_names((native_paths + outside_native).uniq) |
                              IntegerConstants.foreign_const_names((foreign_ruby_srcs + outside_ruby).uniq)
    )
  end
  integer_constants =
    if closed_world.constants_static?
      constant_facts.fixnum_names
    else
      warn "== INTEGER_CONSTANT_PROOF off: constant bindings are not static (#{closed_world.global_refusal || 'dynamic constant mutation'}) =="
      Set.new
    end
  outside_bound = IntegerConstants.native_defined_const_names(native_paths) |
                  IntegerConstants.foreign_const_names(foreign_ruby_srcs)
  # PROMOTE_PROOF: the TC1011 verdict DECLARED_CONSTANT_CHECK would give each constant of a candidate directory if it
  # were declared (scripts/bc2cpp/promote_candidates.rb --proofs). Read before the declared containers below are merged,
  # as the check itself reads them. Only the verdict file is written; the program's own diagnostics are unchanged.
  if (candidate_dir = ENV['BC2CPP_CONSTANT_PROOF_CANDIDATES']) && !candidate_dir.empty?
    proof_out = ENV['BC2CPP_CONSTANT_PROOF_OUT'].to_s
    abort 'bc2cpp: BC2CPP_CONSTANT_PROOF_CANDIDATES needs BC2CPP_CONSTANT_PROOF_OUT' if proof_out.empty?

    require 'json'
    candidate_files = Dir.glob(File.join(candidate_dir, '**', '*.rbs')).sort
    verdicts = DeclaredConstants.verdicts(
      DeclaredConstants.load(candidate_files, candidate_dir, registry.values.flatten.map(&:owner).to_set),
      ireps, registry, constant_assignment_sites, outside_bound, container_constants, candidate_dir,
      plus_safe: DeclaredConstants.array_sum_safe?(registry, superclass_of, prepended_modules, unknown_mixins),
      range_safe: DeclaredConstants.range_to_a_safe?(registry, included_modules, prepended_modules, unknown_mixins)
    )
    File.write(proof_out, "#{JSON.pretty_generate('version' => 1, 'candidates' => File.basename(File.expand_path(candidate_dir)),
                                                  'verdicts' => verdicts)}\n")
    warn "== PROMOTE_PROOF: #{verdicts.size} candidate constant(s) -> #{proof_out} =="
  end
  # DECLARED_CONSTANT_CHECK: RBS constant declarations, checked at every assignment, add the facts the two
  # constant proofs give (INTEGER_CONSTANT_PROOF, CONST_CONTAINER).
  if sig_loaded
    declared_constants = DeclaredConstants.check(
      DeclaredConstants.load(sig_loaded.files, sig_root, registry.values.flatten.map(&:owner).to_set),
      ireps, registry, constant_assignment_sites, integer_constants, outside_bound, container_constants, sig_root,
      plus_safe: DeclaredConstants.array_sum_safe?(registry, superclass_of, prepended_modules, unknown_mixins),
      range_safe: DeclaredConstants.range_to_a_safe?(registry, included_modules, prepended_modules, unknown_mixins)
    )
    integer_constants |= declared_constants.integer_names
    # The registry and LEXICAL_CONST qualify scopes separately; a key is used only where both name the same SETCONST.
    lexical_sites = LexicalConsts.analyze(ireps, static: true).site_keys
    integer_constant_keys = declared_constants.integer_keys.select { |key, insn| lexical_sites[insn] == key }.keys.to_set
    declared_constants.containers.each { |name, klass| container_constants[name] ||= klass }
    sig_applied.ir_const_elements = declared_constants.elements if sig_applied
    DeclaredConstants.report(declared_constants, sig_applied,
                             abort_on_error: !ENV['BC2CPP_TYPE_FACTS'].to_s.then { |v| !v.empty? })
  end
  warn "== integer-valued constants (BYTECODE_CONSTANT_FACTS) =="
  if integer_constants.empty?
    warn '  (none)'
  else
    integer_constants.sort.each { |n| warn "  CONST #{n}" }
  end

  # The values of the admitted names, folded at GETCONST/GETMCNST (CodeGen.integer_constant_values).
  integer_constant_values = constant_facts.values.select { |name, _| integer_constants.include?(name) }
  profile_phase.call('global facts + annotations')
  warn "== integer constant literal values (BYTECODE_CONSTANT_FACTS): #{integer_constant_values.size} of #{integer_constants.size} =="
  integer_constant_values.sort.each { |n, v| warn "  CONST #{n} = #{v}" }
  warn "== BYTECODE_CONSTANT_FACTS: #{constant_facts.paths.size} paths, #{constant_facts.groups.size} names =="
  constant_facts.paths.sort.each do |path, fact|
    warn "  IR_CONST #{path} #{BytecodeIR::ConstantFacts.report_fields(fact).join(' ')}"
  end
  constant_facts.groups.sort.each do |name, fact|
    warn "  IR_GROUP #{name} #{BytecodeIR::ConstantFacts.report_fields(fact).join(' ')}"
  end

  # RECORD_HASH_PROOF: needs the same outside-source picture as
  # IntegerConstants and the closed world, which sees every writer.
  # The trusted tier classifies a writer with the tripwire-backed Array scan
  # the block recognizers already rely on; the default consumer tier is strict.
  record_hash = profile_call.call('RecordHash.analyze') do
    RecordHash.analyze(ireps, registry, native_paths: native_paths, foreign_paths: foreign_ruby_srcs,
                                        closed_world: closed_world,
                                        outside_tokens: outside_world_tokens(native_paths + foreign_ruby_srcs),
                                        trusted: ->(irep, idx, reg) { proven_array_source_scan(irep, idx, reg, registry) == 'Array' })
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
  end
  record_hash.refused.sort.each { |name, why| warn "  RECORD_HASH_REFUSED  @#{name}  (#{why})" }
  warn ''
  # RBS_RECORD_TYPES: checked record declarations join the RECORD_HASH_PROOF table.
  if sig_loaded
    RbsRecordTypes.drive(sig_loaded.files, sig_applied.diagnostics, ireps, registry, display_root: sig_root,
                         closed_world: closed_world, native_paths: native_paths, foreign_paths: foreign_ruby_srcs,
                         superclass_of: superclass_of, container_constants: container_constants)
  end

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

  if type_check_variants
    TypeCheckVariants.fork_variants(type_check_variants)
    # A child's phase timings exclude time spent waiting for earlier variants.
    profile_started = profile_last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  known_owners = registry.values.flatten.map(&:owner).uniq
  class_annotations = sig_class_annotations || profile_call.call('ClassAnnotations.extract') do
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
  # here because the probing pass below needs ARRAY_RETURN_PROOF.

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
  # BC2CPP_SELF_REGISTERING: BC2CPP_WIRED_EMBEDDINGS names the project classes
  # whose embedded layout has been traced end to end. A caller that compiles
  # another program (tools/optcarrot_probe/compiled_run.rb) sets this to skip
  # that allowlist; drop_unsafe_embeddings' other checks still run.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.core_compare = CoreCompare.verified(foreign_ruby_srcs | core_mrbgem_mrblib_srcs(File.expand_path('../..', __dir__)),
                                              native_name_sources)
  warn "== Comparable comparison operators verified against the build's sources (CORE_COMPARE): #{CodeGen.core_compare.to_a.sort.join(', ')} =="
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
  # RBS_SIGNATURES: a declared ivar class fills an ivar the analysis left unknown (guarded hint, like CLASS_HINT); an
  # inferred class is kept and a disagreement is a contradiction in the type check.
  RbsSignatures.seed_table(class_layout, sig_applied.ivar_classes) if sig_applied
  # SUBTREE_DISPATCH: "C or a descendant" receiver facts, read only by the send devirtualization.
  CodeGen.subtree_facts = nil
  if SubtreeFacts.enabled?
    subtree_labels = {}
    registry.each_value { |defs| defs.each { |d| subtree_labels[d.irep] = "#{d.owner}##{d.name}" if d.irep } }
    CodeGen.subtree_facts = SubtreeFacts.build(raw: class_layout_raw, store_log: ivar_store_log, world: closed_world,
                                               exact_layout: class_layout, applied: sig_applied, labels: subtree_labels)
    warn ''
    warn "== subtree receiver facts (SUBTREE_DISPATCH, ADR 0453): #{CodeGen.subtree_facts.sources.size} =="
    CodeGen.subtree_facts.sources.each { |line| warn "  SUBTREE_FACT #{line}" }
  end
  profile_phase.call('class layout fixed-point passes')
  # Step 6c-bis: the same call-site inference ArgTypes does, for the class-name
  # lattice. Its only consumer is RBS_SEED_CONTRADICTION below -- a class
  # annotation is otherwise consumed purely as a SEED into ClassLayout above, so
  # a wrong one silently becomes the fact it seeded. This is deliberately NOT
  # fed back into ClassLayout or IvarLayout: those are fixed points whose
  # order-independence argument must not grow a new input.
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

  # IVAR_POISON_CAUSES: the same OPAQUE list bucketed by what the unresolved stores are.
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
  element_annotations = sig_element_annotations || profile_call.call('ElementAnnotations.extract') do
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
  # ELEMENT_SIGNATURE_CHECK: the classes traced sites wrote, checked against `@x: Array[C]` seeds below.
  element_site_classes = {}
  element_raw = profile_call.call('ArrayElementLayout.analyze') do
    ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                               element_annotations, superclass_of,
                               poison_reason: element_poison_reason, site_classes: element_site_classes,
                               closed_world: closed_world, included_modules: included_modules,
                               prepended_modules: prepended_modules, unknown_mixins: unknown_mixins)
  end
  element_layout = ArrayElementLayout.known(element_raw)
  RbsSignatures.seed_table(element_layout, sig_applied.ivar_elements) if sig_applied
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
  hash_element_site_classes = {}
  hash_element_raw = profile_call.call('HashElementLayout.analyze') do
    HashElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                              element_annotations, element_raw, superclass_of,
                              poison_reason: hash_poison_reason, site_classes: hash_element_site_classes,
                              closed_world: closed_world, included_modules: included_modules,
                              prepended_modules: prepended_modules, unknown_mixins: unknown_mixins)
  end
  hash_element_layout = HashElementLayout.known(hash_element_raw)
  RbsSignatures.seed_table(hash_element_layout, sig_applied.ivar_hash_elements) if sig_applied
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
  # FIXNUM_RETURN_PROOF / ENTRY_ARG_CALLSITE_PROOF: every identifier token of the
  # outside native and Ruby sources (see outside_world_tokens).
  outside_tokens = outside_world_tokens(native_paths + foreign_ruby_srcs)
  # NUMERIC_OPERAND_PROOF: the same two outside inputs, as ivar names they spell
  # and operators they define on NilClass.
  outside_ivars = outside_ivar_names(native_paths + foreign_ruby_srcs)
    # A core mrbgem the build does not link never runs, so its Ruby cannot spell a scoped name: FOREIGN_RUBY_SRCS globs
    # every 3rd/mruby/mrbgems mrblib (mruby-benchmark's Report spells @width), and that spelling would drop a scope
    # for nothing. Every other foreign file still counts.
    gems_dir = File.join(File.expand_path('../..', __dir__), '3rd/mruby/mrbgems/')
    linked_ruby = foreign_ruby_srcs.reject do |path|
      full = File.expand_path(path)
      full.start_with?(gems_dir) && !build_gems.key?(full.delete_prefix(gems_dir).split('/').first)
    end
    native_ivar_scopes, refusal = NativeIvarScopes.analyze(native_paths + outside_native, linked_ruby + outside_ruby)
    warn "== native ivar scopes (ADR 0332): #{refusal || native_ivar_scopes.inspect} =="
    # OUTSIDE_RUBY_IVAR_SCOPES: a name only foreign Ruby spells, and only inside instance methods of known classes,
    # poisons just those classes' families rather than every class (outside_ruby_ivar_scopes.rb).
    _, ruby_scoped = OutsideRubyIvarScopes.analyze(foreign_ruby_srcs)
    native_spelled = outside_ivar_names(native_paths)
    ruby_scopes = ruby_scoped.reject { |name, _| native_spelled.include?(name) || native_ivar_scopes.key?(name) }
                             .select { |name, _| outside_ivars.include?(name) }.transform_values(&:sort)
    native_ivar_scopes = native_ivar_scopes.merge(ruby_scopes)
    warn "== outside Ruby ivar scopes: #{ruby_scopes.sort.to_h.inspect} =="
  nil_operators = nil_class_operator_names(native_paths)
  outside_consts = IntegerConstants.native_defined_const_names(native_paths) |
                       IntegerConstants.foreign_const_names(foreign_ruby_srcs)
  warn ''
  # BC2CPP_SELF_REGISTERING: same guard as for the probing CodeGen above.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.stable_class_constants = profile_call.call('StableClassConstants.analyze') do
    StableClassConstants.analyze(ireps, native_paths, foreign_ruby_srcs, root_label) |
      StableClassConstants.analyze_native(ireps, native_paths, foreign_ruby_srcs)
  end
  warn "== stable class constants (CONST_SITE_CACHE): #{CodeGen.stable_class_constants.size} =="
  CodeGen.stable_value_constants = profile_call.call('StableValueConstants.analyze') do
    StableValueConstants.analyze(ireps, native_paths, foreign_ruby_srcs)
  end
  warn "== stable value constants (CONST_VALUE_CACHE): #{CodeGen.stable_value_constants.size} =="
  CodeGen.stable_value_constants.sort.each { |n| warn "  STABLE_VALUE #{n}" }
  CodeGen.const_bindings = profile_call.call('ConstBindings.analyze') do
    ConstBindings.analyze(ireps, root_label, native_paths, foreign_ruby_srcs, static: closed_world.constants_static?,
                          included: included_modules, prepended: prepended_modules, unknown_mixins: unknown_mixins)
  end
  warn "== const bindings (CONST_BINDING_CACHE): #{CodeGen.const_bindings.size} =="
  # ENUMERATOR_MODEL: the `Enumerator` constant Kernel#to_enum reads, proven apart from StableClassConstants (mruby's
  # chain/lazy gems reopen the class, which that analysis counts as a second definition).
  if CodeGen.enumerator_model
    unstable = EnumeratorModel.constant_unstable_reason(ireps, root_label, native_paths, foreign_ruby_srcs)
    CodeGen.enumerator_model.constant_stable = unstable.nil?
    CodeGen.enumerator_model.reason ||= unstable
  end
  warn "== enumerator model (ADR 0418): to_enum direct #{CodeGen.enumerator_model&.to_enum_direct ? 'proven' : 'refused'}" \
       "#{CodeGen.enumerator_model&.reason ? " (#{CodeGen.enumerator_model.reason})" : ''}, Enumerator constant " \
       "#{CodeGen.enumerator_model&.constant_stable ? 'stable' : 'not stable'} =="
  # NATIVE_SINGLETON_CALL: the native and outside-Ruby sources the proof must account for.
  CodeGen.native_singleton_inputs = { native: native_paths, ruby: foreign_ruby_srcs }
  # COMPUTED_SEND_EXPANSION: frozen Symbol tables a computed-name send may index.
  CodeGen.computed_send_tables = profile_call.call('ComputedSendNames::SymbolTables.analyze') do
    ComputedSendNames::SymbolTables.analyze(ireps, native_paths, foreign_ruby_srcs)
  end
  warn "== frozen Symbol tables (COMPUTED_SEND_EXPANSION): #{CodeGen.computed_send_tables.size} =="
  CodeGen.computed_send_tables.sort.each { |n, names| warn "  SYMBOL_TABLE #{n}  (#{names.size} names)" }
  CodeGen.struct_members = struct_member_lists
  warn "== Struct.new owners with a known member list (STRUCT_INDEX_CACHE): #{CodeGen.struct_members.size} =="
  CodeGen.integer_constant_values = integer_constant_values
  CodeGen.integer_constant_keys = integer_constant_keys || Set.new
  warn "== declared Integer constants proven per definition (LEXICAL_CONST): #{CodeGen.integer_constant_keys.size} =="
  # Constants whose every writer is one frozen-or-literal container class: a read is that class.
  CodeGen.constant_value_classes = constant_facts.groups.filter_map do |name, fact|
    next unless fact.classes && fact.classes.size == 1 && %i[Array Hash String].include?(fact.classes.first)

    [name, fact.classes.first]
  end.to_h.freeze
  # NUMERIC_CONSTANT_RANGES on the IR: the interval of each name (BYTECODE_CONSTANT_FACTS). The kill switch
  # BC2CPP_NUMERIC_CONSTANTS=0 computes nothing, so the output is master's.
  integer_constant_ranges = IntegerConstantRanges.enabled? ? constant_facts.intervals : nil
  CodeGen.integer_constant_ranges = integer_constant_ranges
  warn "== constants with a proven Fixnum interval (NUMERIC_CONSTANT_RANGES): #{CodeGen.integer_constant_ranges&.size.to_i} =="
  (CodeGen.integer_constant_ranges || {}).sort.each { |n, (lo, hi)| warn "  CONST_RANGE #{n} #{lo} #{hi}" }
  CodeGen.stable_class_constants.sort.each { |n| warn "  STABLE_CLASS #{n}" }

  # ---------------------------------------------------------------------------
  # FIXNUM_RETURN_IVAR_HINT: IvarLayout and FIXNUM_RETURN_PROOF depend on each
  # other (trace_type's SEND case trusts a proven Fixnum return, and that proof's
  # source 3 reads @ivar_layout), e.g. optcarrot's `@_pc =
  # peek16(RESET_VECTOR)` where peek16 is proven only through ivar reads.
  # Stratified like ARRAY_RETURN_IVAR_HINT: Level 0 = `ivar_layout` as computed
  # above; Level 1 = FIXNUM_RETURN_PROOF from a probing CodeGen that embeds no
  # ivars (`analysis_only: :fixnum_return`), with every other table already final
  # (none of them take ivar_layout); Level 2 = IvarLayout.analyze with Level 1
  # available to trace_type's SEND arm, passed to the real CodeGen.
  # Sound: Level 1 is the unchanged proof run with no embedded ivar facts, a
  # subset of the final ones (never more permissive). Level 2 only turns UNKNOWN SEND sites into
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
  # DECLARED_RETURN_CHECK: a declaration with an unproven path aborts like RBS_SEED_CONTRADICTION; the
  # type check reports it (TC1010) with the signature diagnostics.
  DeclaredReturns.report(gen, sig_applied, abort_on_error: !ENV['BC2CPP_TYPE_FACTS'].to_s.then { |v| !v.empty? })
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
  # IVAR_SIGNATURE_CONTRADICTION: an RBS ivar declaration that disagrees with the class or slot the analysis
  # settled is the same build error (TypeFacts reports these rows itself, so they stay out of `contradictions`).
  ivar_contradictions = if sig_applied
                          AnnotationContradictions.ivar_conflicts(sig_applied.ivar_sigs, class_layout_raw,
                                                                  ivar_layout, ClassLayout::UNKNOWN) +
                            AnnotationContradictions.ivar_element_conflicts(sig_applied.ivar_sigs, element_site_classes,
                                                                            hash_element_site_classes)
                        else
                          []
                        end
  # TYPE_CHECK: the report front-end reads the settled types as data; a build never sets this.
  type_facts_path = ENV['BC2CPP_TYPE_FACTS']
  type_facts_path = nil if type_facts_path&.empty?
  if type_facts_path
    require_relative 'type_facts'
    TypeFacts.write(type_facts_path, TypeFacts.collect(TypeFacts::Ctx.new(
      ireps: ireps, registry: registry, annotations: annotations, class_annotations: class_annotations,
      element_annotations: element_annotations, arg_types: arg_types, class_arg_types: class_arg_types,
      class_layout_raw: class_layout_raw, class_poison_reason: class_poison_reason, store_log: ivar_store_log,
      poison_buckets: poison_buckets, ivar_layout: ivar_layout, element_raw: element_raw,
      element_poison_reason: element_poison_reason, hash_element_raw: hash_element_raw,
      hash_poison_reason: hash_poison_reason, container_constants: container_constants, gen: gen,
      contradictions: contradictions, dynamic_names: DynamicNames.universe(ireps), call_sites: call_sites,
      root: ENV['BC2CPP_TYPE_FACTS_ROOT'], signature_origins: sig_applied&.origins, signature_locs: sig_applied&.locs,
      signature_diagnostics: sig_applied&.diagnostics&.map(&:to_h), signature_ivars: sig_applied&.ivar_sigs,
      signature_arg_types: sig_applied&.ir_arg_types, signature_contracts: sig_applied,
      included_modules: included_modules, prepended_modules: prepended_modules, unknown_mixins: unknown_mixins,
      constant_sites: constant_assignment_sites, modules: declared_modules, superclass_of: superclass_of,
      integer_constants: integer_constants, element_site_classes: element_site_classes,
      hash_element_site_classes: hash_element_site_classes, integer_constant_ranges: integer_constant_ranges,
      # Report only: codegen never reads it, so a build without BC2CPP_TYPE_FACTS is
      # unchanged. IntegerConstants.class_admitted is the oracle the constant typing check compares against.
      integer_class_constants: if closed_world.constants_static?
                                 class_facts.integer_class_names
                               else
                                 Set.new
                               end
    )))
  end
  warn '== annotation/proof contradictions (RBS_SEED_CONTRADICTION) =='
  if contradictions.empty? && ivar_contradictions.empty?
    warn '  (none)'
  else
    contradictions.each do |owner, name, pos, declared, got|
      where = pos == :return ? 'return' : "position #{pos + 1}"
      warn "  CONTRADICTION #{owner}##{name} #{where}: annotation says #{declared.inspect}, " \
           "inference proved #{got.inspect}"
    end
    ivar_contradictions.each do |sig, declared, got|
      warn "  CONTRADICTION #{sig.owner}#{sig.name} ivar (#{sig.loc.file}:#{sig.loc.line}): signature says " \
           "#{declared}, inference proved #{got}"
    end
    # The type check reports them (with file:line) instead of stopping the run that collects them.
    total = contradictions.size + ivar_contradictions.size
    abort "\n[bc2cpp] RBS_SEED_CONTRADICTION: #{total} declaration(s) disagree with a " \
          "proved type (see above). Fix the declaration, or the code it claims to describe." unless type_facts_path
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
  # NUMERIC_OPERAND_PROOF: the whole-program facts behind the
  # dynamic-send-free arithmetic/compare arms.
  warn '== numeric operand facts (NUMERIC_OPERAND_PROOF) =='
  gen.numeric_facts_report.each { |l| warn l }
  warn ''
  # LCF_ROW_FLOW: whether the LCF object-kind proof is on, and why not.
  warn '== LCF row flow (LCF_ROW_FLOW) =='
  warn(gen.lcf_rows_model ? "  on (#{gen.lcf_rows_model.kinds.size} kinds)" : "  off: #{gen.lcf_rows_refusal}")
  warn ''
  # FROZEN_TABLES: frozen Array/Hash literals whose slot classes are tracked.
  warn '== frozen tables (FROZEN_TABLES) =='
  warn(gen.frozen_tables_model ? "  on (#{gen.frozen_tables_model.shapes.size} shapes)" : "  off: #{gen.frozen_tables_refusal}")
  gen.frozen_tables_report.each { |l| warn l }
  warn ''
  # RETURN_CLASS_TABLE: names whose every definition returns one exact class.
  warn '== return class table (RETURN_CLASS_TABLE) =='
  gen.return_class_report.each { |l| warn l }
  warn ''
  # CLASS_POOLS: ivar and argument class sets pooled across methods.
  warn '== class pools (CLASS_POOLS) =='
  gen.class_pool_report.each { |l| warn l }
  warn ''
  # POOL_DROP_REPORT: why the ivar pools that are not there are not there.
  if ENV['BC2CPP_POOL_DROP_REPORT']
    warn '== class pools dropped: causes (POOL_DROP_REPORT) =='
    gen.pool_drop_report.each { |l| warn l }
    warn ''
  end
  # CONSTRUCTOR_POOLS: initialize arguments joined over every constructor site.
  warn '== constructor pools (CONSTRUCTOR_POOLS) =='
  gen.constructor_pool_report.each { |l| warn l }
  warn ''
  # SHARED_GENERATION: everything above is the same for every unit; each continues from here in its own fork.
  if shared_units
    SharedGeneration.fork_units(shared_units, shared_prefix, shared_stderr, [symbol, out_dir])
    symbol = ENV['OUT_SYMBOL'] || File.basename(srcs.first, '.rb').gsub(/[^a-zA-Z0-9_]/, '_')
    out_dir = ENV['OUT_DIR'] || File.dirname(srcs.first)
  end
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
  # DECLARED_RETURN_GUARD: the analysis trusted every runtime-checked declaration; abort unless this
  # run compiled each one it owns with its guard (before SKIP_UNSUPPORTED could leave one interpreted and unchecked).
  guard_failures = DeclaredReturns.guard_failures(gen.declared_return_hints, compiled, only_owners, other_owners)
  unless guard_failures.empty?
    abort "\n[bc2cpp] DECLARED_RETURN_GUARD: #{guard_failures.size} runtime-checked return declaration(s) " \
          "without their compiled check:\n  #{guard_failures.join("\n  ")}"
  end
  # EMBED_INIT_GUARD: an embedding owner this run emits must get the compiled #initialize that builds its storage.
  embed_failures = EmbedInitGuard.failures(gen.embedding_initializers, compiled, only_owners)
  unless embed_failures.empty?
    abort "\n[bc2cpp] EMBED_INIT_GUARD: #{embed_failures.size} embedded ivar layout(s) without their storage:\n  " \
          "#{embed_failures.join("\n  ")}"
  end
  # TC1005: index ops on a receiver no nil check dominates, collected while the methods compiled.
  if type_facts_path
    require_relative 'type_facts'
    TypeFacts.append_nilable_index(type_facts_path, gen.unguarded_index_sites, ENV['BC2CPP_TYPE_FACTS_ROOT'])
  end

  # Report diagnostics depend on real method compilation, guard checks and TC1005 above,
  # but not translation-unit assembly or its sidecars. Report writers run at exit.
  if type_check_only
    profile_phase.call('type-check report complete')
    exit 0
  end

  # SKIP_UNSUPPORTED=1 drops methods containing `#error` from the output; they
  # stay interpreted. CLI exploration keeps the markers visible; real builds
  # (mrbgem.rake) set this, since a `#error` stops the C++ build.
  unsupported_core_codes = compiled.select { |m| m[:code].include?('#error') && m[:label] && CoreDefs.core_source?(ireps[m[:label]]&.file) }
  skipped_entries = []
  if ENV['SKIP_UNSUPPORTED'] == '1'
    skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }
    unless skipped.empty?
      warn ''
      warn '== skipped (unsupported, left on the interpreter) =='
      skipped.each { |m| warn "  #{m[:owner]}##{m[:name]}: #{m[:code][/^\s*#error (.*)$/, 1]}" }
    end
    skipped_entries = skipped.map { |m| m[:entry] }.compact
  end

  # CORE_INTERPRETED_REPORT: every core-source bytecode method this run leaves
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

  CompactOutput.capture_stdout unless annotated

  # PARAM_TRACE (tools/bc2cpp/param_trace.rb): opt-in runtime classes of compiled method and block
  # parameters; unset (or any value but 1) leaves stdout untouched. Registered BEFORE ELSE_TRACE so the
  # else trace instruments the plain text first (at_exit runs last-in first-out).
  if ENV['BC2CPP_TRACE_TYPES'] == '1'
    require_relative 'param_trace'
    ParamTrace.capture_stdout(
      symbol,
      ParamTrace.method_infos(compiled, ireps: ireps, registry: registry, arg_types: arg_types,
                                        class_arg_types: class_arg_types, annotations: annotations, gen: gen),
      BlockYielders.table(gen)
    )
  end

  # ELSE_TRACE (tools/bc2cpp/else_trace.rb): opt-in counters on the else arm of a core class-tag chain;
  # unset (or any value but 1) leaves stdout untouched.
  if ENV['BC2CPP_TRACE_ELSE'] == '1'
    require_relative 'else_trace'
    ElseTrace.capture_stdout(symbol, compiled.to_h { |m| [m[:impl], "#{m[:owner]}##{m[:name]}"] })
  end

  # RECV_TRACE (tools/bc2cpp/recv_trace.rb): opt-in receiver counters on every by-name send and block call of
  # the generated methods; unset (or any value but 1) leaves stdout untouched. Registered after ELSE_TRACE so it
  # instruments the plain text first (at_exit runs last-in first-out). Both rewrite bc2cpp_send, so not together.
  if ENV['BC2CPP_TRACE_RECV'] == '1'
    abort 'bc2cpp: BC2CPP_TRACE_RECV and BC2CPP_TRACE_ELSE both rewrite bc2cpp_send; set one' if ENV['BC2CPP_TRACE_ELSE'] == '1'
    require_relative 'recv_trace'
    RecvTrace.capture_stdout(symbol, compiled.to_h { |m| [m[:impl], "#{m[:owner]}##{m[:name]}"] })
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
  # SEALED_INT16 (sealed_int16_locals.rb): std::vector<int16_t> locals, only when the switch is on.
  if SealedInt16Locals.enabled?
    puts '#include <cstdint>'
    puts '#include <vector>'
  end
  puts '#include "mrb_array_access.hxx"'
  puts '#include <mruby/class.h>'
  # mrb_range_new for RANGE_INC/RANGE_EXC.
  puts '#include <mruby/range.h>'
  # mrb_protect_error for the RESCUE_SUPPORT bodies (core API, not the
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
  # GC_KEEP_REMOVED: a compiled register is a C local, which the GC does not scan, where the interpreter's register is
  # a VM stack slot it does. A value an mruby API has just unlinked from its container (Array#pop / #shift,
  # Hash#delete) is referenced by nothing else, so the next allocation's GC step could sweep it while the compiled
  # code still holds it -- LRUBitmapCache#[]'s `v = @entries.delete(key); @entries[key] = v` re-inserted a swept
  # Bitmap once mrb_hash_set's String-key copy ran a GC. Each such API is renamed to a wrapper that roots its result
  # in the GC arena, as a new object is rooted, so it lives until the enclosing arena restore, as long as the VM's
  # register would keep it.
  puts <<~'CPP'
    static inline mrb_value bc2cpp_keep_removed(mrb_state* M, mrb_value v) {
      if (!mrb_immediate_p(v)) mrb_gc_protect(M, v);
      return v;
    }
    static inline mrb_value bc2cpp_mrb_ary_pop(mrb_state* M, mrb_value a) { return bc2cpp_keep_removed(M, mrb_ary_pop(M, a)); }
    static inline mrb_value bc2cpp_mrb_ary_shift(mrb_state* M, mrb_value a) { return bc2cpp_keep_removed(M, mrb_ary_shift(M, a)); }
    static inline mrb_value bc2cpp_mrb_hash_delete_key(mrb_state* M, mrb_value h, mrb_value k) {
      return bc2cpp_keep_removed(M, mrb_hash_delete_key(M, h, k));
    }
    #define mrb_ary_pop bc2cpp_mrb_ary_pop
    #define mrb_ary_shift bc2cpp_mrb_ary_shift
    #define mrb_hash_delete_key bc2cpp_mrb_hash_delete_key
  CPP
  # HOT_INLINE: the per-element Array helpers (bc2cpp_ary_entry/push/set, bc2cpp_getidx's front) are a few
  # instructions, but GCC's -O3 inliner drops them from large callers and pays a call per element. -Os builds
  # (the flash-bound boards) keep the compiler's choice. See docs/bc2cpp-hot-inline.md.
  puts <<~'CPP'
    #if defined(__GNUC__) && !defined(__OPTIMIZE_SIZE__)
    #define BC2CPP_HOT_INLINE __attribute__((always_inline))
    #else
    #define BC2CPP_HOT_INLINE
    #endif
  CPP
  # TAGGED_FIXNUM (tagged_fixnum.rb): the Fixnum pair test and the word-level arithmetic and compares.
  print TaggedFixnum::PRELUDE
  # RESPOND_TO_PHANTOM (closed build): see CodeGen#respond_to_phantom_runtime.
  if ENV['BC2CPP_BUILD_NAME'] == 'closed' || !ENV.fetch('BC2CPP_UNREGISTERED_EXTRA', '').empty?
    puts CodeGen.respond_to_phantom_runtime
  end
  # EXCEPTION_BREAK_SUPPORT: the exception a BLOCK_FALLBACK BREAK throws and the
  # call-site glue catches (mruby is built with MRB_USE_CXX_EXCEPTION). Always
  # emitted: a header-only struct with nothing to link.
  # BLOCK_SEMANTICS: each carries the token of the frame it unwinds
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
  CPP
  # The names are read from the RBS table the codegen also uses (CoreFactSigs.proc_call_names), so they cannot
  # drift. Only `"` and `\` need escaping in a C string literal; `[]` and `===` are emitted as they are.
  proc_call_strcmp_tests = CoreFactSigs.proc_call_names.map do |proc_call_name|
    c_name = proc_call_name.gsub(/["\\]/) { |ch| "\\#{ch}" }
    %(!strcmp(name, "#{c_name}"))
  end
  puts "  if (!name || !(#{proc_call_strcmp_tests.join(' || ')})) return false;"
  puts <<~'CPP'
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
    [[noreturn, maybe_unused]] static void bc2cpp_return_from_block(mrb_state* M, mrb_value value, mrb_value token) {
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
    // DECLARED_RETURN_GUARD (ADR 0455): a method with a runtime-checked return declaration (%a{bc2cpp:hint})
    // returned a value of another type. The analysis trusted the declaration as a fact, so this is a hard error:
    // log, then raise BC2cppHintViolation < NoMethodError, as a strict-hint violation does. Never dispatches.
    // -DBC2CPP_NOMETHOD_VERIFY aborts instead, so the verify build stops at the first one.
    #ifdef BC2CPP_NOMETHOD_VERIFY
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_return_violation(mrb_state* M, mrb_value value, const char* method, const char* declared) {
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: declared return violated: %s returned %s, declared -> %s\n", method, mrb_obj_classname(M, value), declared);
      fflush(stderr);
      abort();
    #endif
      mrb_value msg = mrb_format(M, "hint violation: %s returned %T, declared -> %s (%%a{bc2cpp:hint})", method, value, declared);
      mrb_value err = mrb_gv_get(M, mrb_intern_lit(M, "$stderr"));
      mrb_sym puts_id = mrb_intern_lit(M, "puts");
      if (mrb_respond_to(M, err, puts_id)) mrb_funcall_id(M, err, puts_id, 1, mrb_str_plus(M, mrb_str_new_lit(M, "[RPG2k] "), msg));
      struct RClass* klass = mrb_define_class(M, "BC2cppHintViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
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
    // BLOCK_SELF_WORLD (ADR 0477): a compiled block body reads `self` from its env (slot 0, the self of the frame
    // that built it), whatever self the VM passes the cfunc. The VM passes, for a cfunc proc:
    //   * a yield (mrb_yield/mrb_yield_argv via mrb_proc_get_self): nil, with Object as the target class;
    //   * Proc#call (OP_CALL) and OP_BLKCALL: the proc itself, with the proc's own target class;
    //   * a rebinder (mrb_yield_with_class: instance_eval/exec, class_eval/exec, Class.new, Struct.new, ...): the new
    //     self, with its singleton class or the module (nil's is NilClass, never Object);
    //   * a method dispatch of a define_method body: the receiver, with the method's owner; the body is a strict
    //     copy of the proc, which only the method table holds.
    // The last two run the body under another object, which the compiled body cannot honour: a closed-world
    // violation, raised before the body runs. A nil receiver of a method defined on Object looks like a yield, so a
    // strict proc there is told apart by the method table. Emitted only where the world does not prove that no
    // rebinder ever receives a compiled block (BlockSelfWorld).
    [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_block_self_violation(mrb_state* M, mrb_value self, const struct RProc* p, const char* block) {
      const struct REnv* e = MRB_PROC_ENV(p);
      const char* where = block ? block : mrb_sym_name(M, e->mid);
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: compiled block of %s run under another self (%s)\n", where ? where : "?", mrb_obj_classname(M, self));
      fflush(stderr);
      abort();
    #endif
      mrb_value msg = mrb_format(M, "closed-world guard violation: compiled block of %s run under %T instead of its creator's self (BLOCK_SELF_WORLD)", where ? where : "?", self);
      mrb_value err = mrb_gv_get(M, mrb_intern_lit(M, "$stderr"));
      mrb_sym puts_id = mrb_intern_lit(M, "puts");
      if (mrb_respond_to(M, err, puts_id)) mrb_funcall_id(M, err, puts_id, 1, mrb_str_plus(M, mrb_str_new_lit(M, "[RPG2k] "), msg));
      struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
    }
    static inline bool bc2cpp_proc_method_body_p(mrb_state* M, mrb_value self, mrb_sym mid, const struct RProc* p) {
      struct RClass* c = mrb_class(M, self);
      mrb_method_t m = mrb_method_search_vm(M, &c, mid);
      return !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_PROC_P(m) && MRB_METHOD_PROC(m) == p;
    }
    static inline void bc2cpp_block_self_check(mrb_state* M, mrb_value self, const char* block) {
      const mrb_callinfo* ci = M->c->ci;
      const struct RProc* p = ci->proc;
      if (mrb_obj_eq(M, self, MRB_PROC_ENV(p)->stack[0])) return;
      struct RClass* tc = mrb_vm_ci_target_class(ci);
      if (mrb_nil_p(self) && tc == M->object_class &&
          (!MRB_PROC_STRICT_P(p) || !bc2cpp_proc_method_body_p(M, self, ci->mid, p))) return;
      if (mrb_proc_p(self) && mrb_proc_ptr(self) == p && tc == MRB_PROC_TARGET_CLASS(p)) return;
      bc2cpp_block_self_violation(M, self, p, block);
    }
    // The last env slot of a direct-entry block: bit 0 YIELD_FREE (ADR 0283), bit 1 the BLOCK_SELF_WORLD check.
    static const mrb_int BC2CPP_BLOCK_YIELD_FREE = 1;
    static const mrb_int BC2CPP_BLOCK_SELF_CHECK = 2;
    inline mrb_value bc2cpp_block_thunk(mrb_state* M, mrb_value self) {
      const struct RProc* p = M->c->ci->proc;
      const struct REnv* e = MRB_PROC_ENV(p);
      if (mrb_integer(e->stack[MRB_ENV_LEN(e) - 1]) & BC2CPP_BLOCK_SELF_CHECK) bc2cpp_block_self_check(M, self, nullptr);
      mrb_value* argv;
      mrb_int argc;
      mrb_get_args(M, "*", &argv, &argc);
      return bc2cpp_block_entry(MRB_PROC_ENV(p))(M, MRB_PROC_ENV(p), MRB_PROC_STRICT_P(p), argc, argv);
    }
    // STACK_BLOCK (docs/bc2cpp-stack-blocks.md): the RProc and REnv of a direct-entry block passed only to a
    // callee that just calls it, laid out as mrb_proc_new_cfunc_with_env builds them but in the caller's frame,
    // over the caller's own env array. Red, so the GC never marks, gray-lists or sweeps them.
    struct Bc2cppStackBlock {
      struct RProc proc;
      struct REnv env;
      Bc2cppStackBlock(mrb_state* M, mrb_int len, mrb_value* stack) {
        memset(static_cast<void*>(this), 0, sizeof(*this));
        env.tt = MRB_TT_ENV;
        env.gc_color = MRB_GC_RED;
        env.c = mrb_vm_ci_target_class(M->c->ci);
        env.mid = M->c->ci->mid;
        env.stack = stack;
        MRB_ENV_SET_LEN(&env, len);
        MRB_ENV_CLOSE(&env);
        proc.tt = MRB_TT_PROC;
        proc.gc_color = MRB_GC_RED;
        proc.c = M->proc_class;
        proc.flags = MRB_PROC_CFUNC_FL | MRB_PROC_ENVSET;
        proc.body.func = bc2cpp_block_thunk;
        proc.e.env = &env;
      }
      Bc2cppStackBlock(const Bc2cppStackBlock&) = delete;
      Bc2cppStackBlock& operator=(const Bc2cppStackBlock&) = delete;
      mrb_value value() { return mrb_obj_value(&proc); }
    };
    // YIELD_REACH (ADR 0283): the last env slot of a direct-entry block says its body, and everything
    // it can call, provably never suspends a Fiber. A compiled core iterator running such a block
    // may then stay compiled under a Fiber (its frame cannot be crossed by a yield).
    static inline bool bc2cpp_block_yield_free(mrb_value blk) {
      if (mrb_type(blk) != MRB_TT_PROC) return false;
      const struct RProc* p = mrb_proc_ptr(blk);
      if (!MRB_PROC_CFUNC_P(p) || MRB_PROC_CFUNC(p) != bc2cpp_block_thunk) return false;
      const struct REnv* e = MRB_PROC_ENV(p);
      return (mrb_integer(e->stack[MRB_ENV_LEN(e) - 1]) & BC2CPP_BLOCK_YIELD_FREE) != 0;
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
  # IO_PUTS_MODEL: one shared body for every explicit-receiver `puts`, so the
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
  #     setjmp/longjmp the destructor would not run. build_config.rb's closed
  #     stanza says why that configuration is required.
  # Nothing may escape the destructor (std::terminate during unwinding), so the
  # ensure body runs under mrb_protect_error, which also pops the callinfo stack
  # back (vm.c MRB_CATCH arm) and restores the GC arena. Registers live before
  # the guard were allocated below that arena index, so they stay protected.
  # MRB_THROW needs mruby/throw.h, which <mruby.h> does not include.
  puts '#include <mruby/throw.h>'
  # std::uncaught_exceptions(): the guard's "is an unwind in flight" test (see
  # the guard).
  puts '#include <exception>'
  # KERNEL_LOOP_INLINE (codegen_kernel_loop.rb): an inlined Kernel#loop runs its body under its own mrb_jmpbuf.
  # The guard puts M->jmp back on every way out of the loop. The rescue answers a StopIteration with its result,
  # after popping the callinfo frames the raise left (as mrb_protect_error does); anything else, a break object
  # included, is thrown on to the jmpbuf the loop found, untouched, as if the loop had not caught it.
  puts <<~'KERNEL_LOOP'
    struct bc2cpp_jmp_restore {
      mrb_state* M;
      struct mrb_jmpbuf* prev;
      ~bc2cpp_jmp_restore() { M->jmp = prev; }
    };
    [[maybe_unused]] static mrb_value bc2cpp_loop_rescue(mrb_state* M, const Bc2cppVmMark& mark) {
      M->jmp = mark.jmp;
      mrb_value exc = M->exc ? mrb_obj_value(M->exc) : mrb_nil_value();
      if (mrb_nil_p(exc) || mrb_break_p(exc) ||
          !mrb_obj_is_kind_of(M, exc, mrb_class_get(M, "StopIteration"))) {
        if (!M->jmp) { mrb_print_error(M); abort(); }
        MRB_THROW(M->jmp);
      }
      bc2cpp_vm_restore(M, mark);
      M->exc = NULL;
      return mrb_funcall_argv(M, exc, mrb_intern_lit(M, "result"), 0, nullptr);
    }
  KERNEL_LOOP
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
  print gen.emit_ary_write_helpers(compiled)
  print gen.emit_to_enum_helper(compiled)
  print gen.emit_collect_direct_helper(compiled)
  print gen.emit_transpose_direct_helper(compiled)
  print gen.emit_array_hash_helper(compiled)
  print gen.emit_bool_check_helper(compiled)
  print gen.emit_native_core_helpers(compiled)
  print gen.emit_numeric_proof_helpers(compiled)
  print gen.emit_const_lookup_helper
  print gen.emit_native_construct_decls
  print gen.emit_direct_construct_decls
  print gen.emit_stringio_read_decl
  print gen.emit_forward_decls(compiled)
  print gen.emit_resumable_helpers(compiled)
  print gen.emit_instance_tt_setup(compiled)
  print gen.emit_core_guard_helpers(compiled)
  # OUTLINED_INDEX_OPS: built before the owner-class slots are numbered and printed.
  gen.prepare_index_helpers(compiled)
  gen.reserve_poly_table_slots(compiled)
  gen.reserve_numeric_slow_ruby_arm_slots
  print gen.emit_owner_class_cache
  print gen.emit_direct_construct_accessors(compiled)
  # OWNER_METHOD_REGISTRATION: every owner this gem compiles an entry for. No registration is written by hand.
  registration_owners, core_owners = bc2cpp_registration_owners(compiled.map { |m| m[:owner] })
  print gen.emit_owner_registrations(compiled, registration_owners, core_owners: core_owners)
  # SKIPPED_ENTRY_MACROS: the entries this run refused (SKIP_UNSUPPORTED), e.g. a method that compiles only when the
  # closed world proves a fact a desktop build lacks, as `#define BC2CPP_SKIPPED_<entry>` markers.
  print gen.emit_skipped_entry_macros(skipped_entries)
  # SYMBOL_CACHE: rewrite every function first, so the table is complete before
  # it is printed ahead of the code that uses it.
  symbol_table = SymbolCache::Table.new
  # GUARD_VIOLATION: name the method a violation site sits in.
  # Fuse the three per-method rewrite passes (@@SITE@@ substitution, DIRECT_RAISE, SymbolCache.rewrite) into one.
  compiled.each do |m|
    code = m[:code].gsub('@@SITE@@') { "#{m[:owner]}##{m[:name]}".gsub(/["\\]/) { |c| "\\#{c}" } }
    m[:code] = SymbolCache.rewrite(code, symbol_table)
  end
  # Fused single pass over the compiled methods: all of these closed-world diagnostic counts used to
  # live in separate `.each`/`.sum` scans of the same code strings.
  kept = Hash.new(0)
  converted = 0
  dropped = 0
  violation_families = Hash.new(0)
  owner_call = 0
  nilable_receiver = 0
  compiled.each do |m|
    code = m[:code]
    code.scan(%r{/\* CLOSED_WORLD kept: (\w+) \*/}) { |(r)| kept[r] += 1 }
    converted += code.scan(/\bbc2cpp_nomethod\(M,/).size
    dropped += code.scan(%r{^\s*// CLOSED_WORLD_SELF :}).size
    code.scan(/"[^"\n]* \((NEW_IDENTITY|CLASS_ARGUMENT|CLASS_EQQ|CLASS_NARROWING|COMPUTED_SEND|CORE_BODY_EXACT|CHECKED_POOL_EXACT|SELF_NEW_LEAF)\)"/) { |(f)| violation_families[f] += 1 }
    owner_call += code.scan('/* CLOSED_WORLD owner-call: ').size
    nilable_receiver += code.scan(%r{^\s*// NILABLE_RECEIVER :}).size
  end
  warn "== closed world fallbacks: #{dropped} guards dropped, #{converted} bc2cpp_nomethod, " \
       "#{kept.values.sum} kept dispatching =="
  warn "== closed world guard violations: #{violation_families.values.sum} bc2cpp_guard_violation =="
  violation_families.sort.each { |f, n| warn "  GUARD_VIOLATION #{f}: #{n}" }
  NomethodReviewed.violation_sites(compiled).uniq.sort.each { |k| warn "  GUARD_VIOLATION_SITE #{k}" }
  kept.sort_by { |r, n| [-n, r] }.each { |r, n| warn "  KEPT #{r}: #{n}" }
  warn "  OWNER_CALL: #{owner_call}"
  warn ''
  nil_sites = NomethodReviewed.nil_receiver_sites(compiled)
  warn "== closed world nil receivers: #{nil_sites.size} bc2cpp_nil_receiver =="
  warn "  NILABLE_RECEIVER sites: #{nilable_receiver}"
  nil_sites.uniq.sort.each { |k| warn "  NIL_RECEIVER_SITE #{k}" }
  warn ''
  # NOMETHOD and PROVEN_MISS sites are listed on stderr; no review gate judges them. The update scripts read the listings
  # of a run that fails only here (NomethodReviewedProbe.review_abort?).
  review_scope = ReviewScope.for_build(ENV['BC2CPP_BUILD_NAME'].to_s)
  leaked = ReviewScope.leaks(review_scope, only_owners, compiled)
  unless leaked.empty?
    abort "bc2cpp: an engine-owner run compiled owner(s) outside the reviewed scope (tools/bc2cpp/review_scope.rb): " \
          "#{leaked.join(', ')}"
  end
  nomethod_sites = NomethodReviewed.sites(compiled)
  warn "== closed world nomethod sites: #{nomethod_sites.size} =="
  nomethod_sites.each { |s| warn "  NOMETHOD #{s[:key]}#{' [self]' if s[:self_receiver]}" }
  warn ''
  hint_sites = []
  unless StrictHints.families.empty?
    hint_sites = StrictHints.sites(compiled)
    warn "== strict hints (#{StrictHints.families.join(',')}): #{hint_sites.size} bc2cpp_hint_violation =="
    StrictHints.family_counts(compiled).sort.each { |f, n| warn "  STRICT_HINT #{f}: #{n}" }
    hint_sites.map { |s| s[:key] }.uniq.sort.each { |k| warn "  STRICT_HINT_SITE #{k}" }
    warn ''
  end
  # DECLARED_RETURN_GUARD: one forced check per exit wrapper of a runtime-checked return declaration.
  guard_sites = DeclaredReturns.guard_sites(compiled)
  warn "== declared return guards (DECLARED_RETURN_GUARD): #{guard_sites.size} bc2cpp_declared_return_violation =="
  guard_sites.uniq.sort.each { |k| warn "  DECLARED_RETURN_GUARD_SITE #{k}" }
  warn ''
  miss_sites = ProvenMiss.sites(compiled)
  warn "== closed world proven-class miss sites: #{miss_sites.size} =="
  miss_sites.each { |s| warn "  PROVEN_MISS #{s[:key]}" }
  warn ''
  unless review_scope == ReviewScope::ALL
    outside = [nomethod_sites, hint_sites, miss_sites].sum { |l| l.size - ReviewScope.select(review_scope, l).size }
    warn "== review scope: engine owners; #{outside} listed site(s) outside the reviewed program ==" if outside.positive?
  end
  # OUTLINED_INDEX_OPS: after the symbol cache (their fallbacks become
  # bc2cpp_send too), ahead of every function that calls them.
  index_helpers_code = SymbolCache.rewrite(gen.emit_index_helpers(compiled), symbol_table)
  # NUMERIC_SLOW_PATH: the by-name calls of the numeric arms' else live here once per helper.
  numeric_slow_code = SymbolCache.rewrite(gen.emit_numeric_slow_helpers(compiled), symbol_table)
  warn "== numeric slow-path helpers: #{gen.numeric_slow_site_counts(compiled).map { |k, n| "#{k} #{n}" }.join(', ').then { |s| s.empty? ? 'none' : s }} sites =="
  warn ''
  warn "== outlined index ops: #{gen.index_helper_site_counts(compiled).map { |k, n| "#{k} #{n}" }.join(', ')} sites =="
  warn "== index helpers closed (INDEX_CLOSED, ADR 0365): #{gen.index_closed_summary(compiled)} =="
  warn "== integer-tag else (INTEGER_TAG_ELSE, ADR 0394): #{gen.integer_tag_else_summary} ==" if gen.integer_tag_else_enabled?
  warn ''
  eqq_helper_code = SymbolCache.rewrite(gen.emit_eqq_helper(compiled), symbol_table)
  warn "== shared === helper (EQQ_DIRECT): #{gen.eqq_helper_site_count(compiled)} sites =="
  warn ''
  if CodeGen.subtree_facts
    subtree_sites = gen.subtree_site_counts(compiled)
    warn "== subtree dispatch (SUBTREE_DISPATCH, ADR 0453): #{subtree_sites.sum(&:last)} sites =="
    subtree_sites.each { |(kind, name, root), count| warn "  #{kind} :#{name} on #{root}: #{count}" }
    warn ''
  end
  poly_table_sites = gen.poly_table_site_counts(compiled)
  warn "== poly table dispatch: #{poly_table_sites.map { |t, n| "#{t} #{n}" }.join(', ').then { |s| s.empty? ? 'none' : s }} sites =="
  warn ''
  poly_tables_code = gen.emit_poly_tables(compiled)
  # A constant helper is emitted only when the printed text calls it: a body compiled and then discarded
  # registers its helpers too. The site-cache helpers call the scope helpers, so they are counted first.
  used = [index_helpers_code, eqq_helper_code, numeric_slow_code, poly_tables_code, *compiled.map { |m| m[:code] }].join
  const_site_cache_code = SymbolCache.rewrite(gen.emit_const_site_cache(used), symbol_table)
  const_scope_code = SymbolCache.rewrite(gen.emit_const_scope_helpers(used + const_site_cache_code), symbol_table)
  print SymbolCache.emit(symbol_table)
  print const_scope_code
  print const_site_cache_code
  print index_helpers_code
  print eqq_helper_code
  print numeric_slow_code
  print poly_tables_code
  compiled.each { |m| print m[:code] }
  print gen.emit_gem_hooks

  # This run's cross-TU declarations header, for other gems'
  # OTHER_DECLS_HEADER (see emit_decls_header). Always written.
  File.write(File.join(out_dir, "#{symbol}_decls.h"), gen.emit_decls_header(compiled))
  # BC2CPP_ENTRY: the host-callable entry header (codegen_entry_header.rb), beside the declarations and, when
  # BC2CPP_ENTRY_INCLUDE_DIR names it, in the build's include directory, where every host's `__has_include` finds it.
  entry_header = gen.emit_entry_header(compiled, symbol)
  File.write(File.join(out_dir, "#{symbol}_entry.h"), entry_header)
  if (entry_dir = ENV['BC2CPP_ENTRY_INCLUDE_DIR'])
    FileUtils.mkdir_p(entry_dir)
    File.write(File.join(entry_dir, "#{symbol}_entry.h"), entry_header)
  end
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

  # CORE_DEFS: which of those bodies come from mruby's own Ruby, for the
  # coverage report's engine/core split.
  core_entries = compiled.select { |m| m[:label] && CoreDefs.core_source?(ireps[m[:label]]&.file) }
  warn ''
  warn "== core-source compiled entry points (#{core_entries.size}) =="
  core_entries.each { |m| warn "  #{m[:owner]}##{m[:name]}" }

  # ARRAY_NEW_BLOCK: `Array.new(n) { }` sites the closed world inlined, and why the others kept the call.
  warn ''
  warn '== Array.new block inlining (ARRAY_NEW_BLOCK) =='
  gen.array_new_report.sort.each { |reason, count| warn "  #{reason}: #{count}" }

  # YIELD_REACH: what the yield-free proof gave this build.
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
  native_call_names = extract_native_call_names(native_paths)
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
  profile_phase.call('diagnostics + sidecar writes')
end
