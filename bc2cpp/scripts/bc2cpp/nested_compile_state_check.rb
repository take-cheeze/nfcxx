#!/usr/bin/env ruby
# encoding: UTF-8
# Check that a nested compile (compiles_clean? probing a callee in the middle
# of another method's compile) neither sees nor clobbers the caller's
# per-method state (ADR 0202). Each fixture method calls a MONO helper inside a
# block-fallback body, then uses state the helper's own compile used to clear:
# an upvar write, a forwarded `yield`, a `break`. The result must not depend on
# whether the helper was already memoized.
#
# Also checks that METHOD_COMPILE_STATE lists every ivar CodeGen writes outside
# its constructor, except the memo caches, output accumulators and
# constructor-time proofs named below.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~'RUBY'
  class Pages
    def helper(x)
      x.each { |y| y }
    end

    def changed?(list)
      acc = 0
      list.each { |v| helper(v); acc = v }
      acc
    end

    def each_page(list)
      list.each { |v| helper(v); yield v }
    end

    def first_page(list)
      list.each { |v| helper(v); break v if v }
    end
  end
RUBY

ireps, registry = Dir.mktmpdir do |dir|
  path = File.join(dir, 'pages.rb')
  File.write(path, SOURCE)
  parsed, root_label = compile_ireps(path, 'bc2cpp_pages', dir)
  order = dfs_order(parsed, root_label)
  [parsed, build_registry(parsed, root_label)[0]]
end
new_gen = -> { CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new) }
label = ->(name) { registry.fetch(name).find { |d| d.owner == 'Pages' }.irep }
state_of = ->(gen) { CodeGen::METHOD_COMPILE_STATE.keys.to_h { |ivar| [ivar, gen.instance_variable_get(ivar)] } }

{ 'changed?' => 'an upvar write', 'each_page' => 'a forwarded yield', 'first_page' => 'a break' }.each do |name, what|
  cold = new_gen.call
  cold_code = cold.compile_method(label.call(name)).fetch(:code)
  warm = new_gen.call
  warm.compiles_clean?(label.call('helper'))
  warm_code = warm.compile_method(label.call(name)).fetch(:code)
  check.call("#{name}: #{what} after a first-time helper probe compiles clean", !cold_code.include?('#error'))
  check.call("#{name}: the code does not depend on whether the helper was memoized", cold_code == warm_code)
  check.call("#{name}: its own memo is clean", new_gen.call.compiles_clean?(label.call(name)))
  check.call("#{name}: every per-method ivar is back at its top-level value",
             state_of.call(cold) == CodeGen::METHOD_COMPILE_STATE)
end
first_page = new_gen.call.compile_method(label.call('first_page')).fetch(:code)
check.call('first_page: the block break still throws out of the block cfunc',
           first_page.include?('bc2cpp_break(M, '))

fresh = new_gen.call
check.call('METHOD_COMPILE_STATE matches the constructor\'s initial values',
           CodeGen::METHOD_COMPILE_STATE.all? { |ivar, v| fresh.instance_variable_get(ivar) == v })

# Every ivar written outside `initialize`, split by what it is. @closed_world is swapped out for the
# body of a core method (ADR 0264) and restored by an `ensure` before compile_method returns;
# @core_program_world holds it for the arms of ADR 0270 and is cleared by the same `ensure`.
# The textual scan also sees fields of the nested flow-oracle objects.
# ADR 0380: @entry_spec_plan (the parsed BC2CPP_SPECIALIZE file) and @entry_spec_cache (label -> specialization) are
# program-wide memos; @entry_spec_active and @entry_spec_suffix are set around the clone compile and restored by
# its own `ensure` in entry_specialize_compile, so a nested compile never sees them half-set.
# ADR 0391: @symbol_installed_destinations is a program-wide memo like @symbol_installed_names; @array_new_sites is the
# ARRAY_NEW_BLOCK report, a write-once-per-site tally keyed by [irep label, index] (a nested compile of the same site
# stores the same outcome).
NOT_PER_METHOD = %w[
  @symbol_installed_destinations @array_new_sites
  @clean_cache @probing
  @builtin_class_send_safe @entry_arg_body_owner @entry_arg_call_index @eqq_direct_safe @eqq_helper_code
  @eqq_literal_devirt_safe
  @fixnum_proof_ctx @keyword_never_defined_universe @known_owner_set @subclassed_set
  @own_upvar_written_regs @symbol_installed_names
  @const_lookup_helper_used @const_site_cache @direct_construct_used @index_helper_code @native_construct_used
  @owner_class_cache @synthesize_accessor_for @poly_tables @poly_tables_emitted
  @rc_new_class @rc_oracle @rc_return @rc_send_ireps @rc_states @numeric_class_bits
  @rc_scoped_return_cache @rc_scoped_return_active @rc_scoped_ready @rc_scoped_states
  @rc_scoped_writes @rc_scoped_active_labels @rc_body_owners
  @pool_self_class_refusal @rc_load_self_oracles
  @array_return_names @class_return_names @entry_arg_fixnum @fixnum_return_names @fiber_unsafe_methods
  @fiber_roots @fiber_yield_names @resumable_plans @resumable_warned
  @yf_blocks @yf_arm_sites
  @ivar_layout @only_owners @other_owners
  @closed_world @core_program_world
  @constant_object_probe @direct_alloc_used @poly_diagnostic_reason_cache @rescued_exception_message_safe
  @sanitized @strict_ancestors @subtree_ivar_names @rescue_covered_labels @record_key_exact_class
  @foreign_written_ivar_facts
  @entry_spec_plan @entry_spec_cache @entry_spec_active @entry_spec_suffix
  @cg @receiver @arguments @contexts @context_enter_edges @entry_arg_numeric @entry_cand @numeric_allocate_free @numeric_assured @numeric_block_parents
  @numeric_const_groups @numeric_dynamic_names @numeric_family_find @numeric_irep_owner @numeric_irep_slots
  @numeric_ivar_disabled @numeric_ivar_groups @numeric_nil_raises @numeric_op_native @numeric_oracle
  @lcf_rows @lcf_rows_refusal
  @frozen_tables @frozen_tables_refusal @frozen_table_sites @frozen_table_name_safe
  @class_arg_pools @class_const_pools @class_ivar_pools @class_pools_on @kernel_freeze_only @nil_ancestor_modules @nil_unanswerable
  @numeric_return @numeric_return_send_ireps @numeric_states @numeric_wild_families @numeric_writes
  @core_ruby_name_results @native_result_kinds @native_result_name_kinds @native_results_ready @native_struct_string_alias_safe @native_dup_result_safe
  @captured_local_class_enabled @rc_writes
  @profiler_result_lookup @profiler_result_parents
  @tuple_returns @tuple_sites @tuple_consumers @numeric_root_depth @numeric_root_lines
  @escape_analyzer
  @constructor_pool_candidates @constructor_pool_status @constructor_pool_refusal @constructor_pool_stats @constructor_aliased
  @constructor_body_classes @constructor_chain
  @call_facts_answers @call_facts_states @call_facts_classes @symbol_instance_installed_names @nil_unanswerable_instances
  @numeric_slow_closed_cmp @numeric_slow_misc @numeric_slow_collection_ready @core_compiled_by_name @core_compiled_hash_cmp @numeric_slow_zero
  @index_closed_plan @index_closed_reasons @index_helper_requested @index_mruby_root @index_sources @index_outside_supers
  @setter_arg_candidates @setter_literal_names @setter_outside_names @setter_pool_reads @setter_pool_refusal @checked_pools_used
  @aliased_operand_names @rc_checked_alias_names @rc_admitted_alias_names
  @class_tests @class_test_subjects @class_test_objects @class_test_positive @class_test_name_safe @class_object_eq_safe
  @class_narrowing_raise @core_class_subclass_free @kind @klass @partitions
  @integer_tag_else_bodies_used @integer_tag_else_counts
  @native_owner_map_targets
].freeze
# ADR 0397: @native_owner_map_targets memoizes, per method name and arity, the program-wide candidate set of
# the NATIVE_OWNER_MAP arms (a nested compile of the same name computes the same set).
# ADR 0394: the INTEGER_TAG_ELSE body set and refusal tally are program-wide accumulators. A nested compile of the
# same site writes the same body name, and the tally only feeds the stderr summary.
# CodeGen is reopened across several tools/bc2cpp files (scripts/bc2cpp/split.rb).
written = Set.new
blocks = 0
Dir[File.join(root, 'tools/bc2cpp/*.rb')].sort.each do |path|
  lines = File.readlines(path)
  lines.each_index.select { |i| lines[i] == "class CodeGen\n" }.each do |first|
    blocks += 1
    last = first + lines[first..].index("end\n")
    in_init = false
    lines[first..last].each do |line|
      in_init = true if line.start_with?('  def initialize(')
      in_init = false if in_init && line == "  end\n"
      next if in_init

      code = line.sub(/(^|\s)#.*$/, '')
      code.scan(/(@[a-z_]\w*)\s*(?:\|\|=|\+=|<<|=(?![=~]))/) { |(ivar)| written << ivar }
    end
  end
end
check.call("CodeGen's source is found (#{blocks} class bodies)", blocks.positive?)
unlisted = written.to_a - CodeGen::METHOD_COMPILE_STATE.keys.map(&:to_s) - NOT_PER_METHOD
check.call("every ivar written outside the constructor is classified#{unlisted.empty? ? '' : " (not: #{unlisted.sort.join(', ')})"}",
           unlisted.empty?)

if failures.empty?
  puts 'bc2cpp nested compile state check: PASS'
else
  warn "bc2cpp nested compile state check: #{failures.size} failure(s)"
  exit 1
end
