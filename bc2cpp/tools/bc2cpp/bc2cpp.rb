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
# Input comes from mrbc's two debug dumps of the same sources: `-v` (opcode
# mnemonics, DFS pre-order blocks) and `-B -S` (the C irep structs, with exact
# pool/symbol/lv arrays and reps[] parent/child pointers). Neither alone is
# enough, so the C dump's tree is walked in DFS pre-order and zipped against
# the disassembly's block sequence.

require 'shellwords'
require 'set'

# Parts split out by scripts/bc2cpp_split.rb, loaded in original definition order.
require_relative 'irep'
require_relative 'registry'
require_relative 'native_names'

require_relative 'native_expression_devirt'
require_relative 'symbol_cache'
require_relative 'const_site_cache'
require_relative 'static_dispatch_unregistered'
require_relative 'unique_class_names'
require_relative 'closed_world'
require_relative 'nomethod_reviewed'
require_relative 'hot_methods'

require_relative 'integer_constants'
require_relative 'native_construct_schema'
require_relative 'ivar_layout'
require_relative 'annotations'
require_relative 'class_layout'
require_relative 'element_layouts'
require_relative 'diagnostics'
require_relative 'dispatch_targets'
require_relative 'irep_arity'
require_relative 'codegen'
require_relative 'codegen_ivar_poly'
require_relative 'codegen_native_send'
require_relative 'codegen_receiver_facts'
require_relative 'codegen_emit'
require_relative 'codegen_method'
require_relative 'codegen_rescue'
require_relative 'codegen_loop_regions'
require_relative 'codegen_fixnum_proof'
require_relative 'codegen_return_analysis'
require_relative 'codegen_loop_inline'
require_relative 'codegen_block_fallback'
require_relative 'codegen_runtime_def'
require_relative 'codegen_insn'
require_relative 'codegen_keyword_send'
require_relative 'codegen_send'

if $PROGRAM_NAME == __FILE__
  srcs = ARGV
  raise 'usage: bc2cpp.rb file1.rb [file2.rb ...]  (env: MRBC, OUT_SYMBOL, OUT_DIR, ONLY_OWNERS)' if srcs.empty?

  symbol = ENV['OUT_SYMBOL'] || File.basename(srcs.first, '.rb').gsub(/[^a-zA-Z0-9_]/, '_')
  out_dir = ENV['OUT_DIR'] || File.dirname(srcs.first)

  c_src, disasm_text = run_mrbc(srcs, symbol, out_dir)
  ireps, root_label = parse_c_dump(c_src, symbol)
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm_text)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry, superclass_of, container_constants, included_modules, prepended_modules, unknown_mixins,
    struct_member_lists, class_decls, walked_ireps, module_body_ivar_labels = build_registry(ireps, root_label)

  # NATIVE_SRCS: C/C++ sources to scan for mrb_define_method-family calls (see
  # extract_native_method_names). Without it the registry cannot see native
  # definitions.
  native_name_sources = nil
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
    bytecode_methods = registry.values.flatten.count(&:irep)
    warn ''
    warn "== hot-only (BC2CPP_HOT_METHODS): #{hot_methods.size} listed, #{CodeGen.hot_only_excluded.size} of " \
         "#{bytecode_methods} bytecode methods excluded =="
    HotMethods.stale(registry, hot_methods).each { |k| warn "  STALE #{k}" }
  end

  arg_types = ArgTypes.analyze(ireps, registry)
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

  annotations = Annotations.extract(ireps, registry)
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
  foreign_methods = foreign_ruby_srcs ? foreign_method_names(foreign_ruby_srcs) : nil

  # UNIQUE_CLASS_NAME: set before the first ClassLayout pass, since every
  # trace_new_target caller reads it.
  UniqueClassNames.table = UniqueClassNames.analyze(ireps, root_label, native_paths, foreign_ruby_srcs)
  UniqueClassNames.object_mixins = Array(included_modules['Object'])
  warn '== bare class names with one definition (UNIQUE_CLASS_NAME) =='
  UniqueClassNames.table.sort.each { |name, full| warn "  UNIQUE_CLASS  #{name}  (#{full})" }

  integer_constants =
    if ENV['NATIVE_SRCS'] && foreign_ruby_srcs
      IntegerConstants.analyze(ireps, native_paths, foreign_ruby_srcs)
    else
      Set.new
    end
  warn "== integer-valued constants proven (INTEGER_CONSTANT_PROOF) =="
  if integer_constants.empty?
    warn '  (none)'
  else
    integer_constants.sort.each { |n| warn "  CONST #{n}" }
  end

  integer_constant_values = IntegerConstants.analyze_values(ireps, integer_constants)
  warn "== integer constant literal values proven (INTEGER_CONSTANT_VALUE_PROOF): #{integer_constant_values.size} of #{integer_constants.size} =="
  integer_constant_values.sort.each { |n, v| warn "  CONST #{n} = #{v}" }

  # FIXNUM_RETURN_IVAR_HINT: Level 0 IvarLayout (no FIXNUM_RETURN_PROOF evidence).
  # The `== ivar embedding ==` diagnostic is printed later from the final
  # (Level 2) table, so this call is silent.
  ivar_layout = IvarLayout.analyze(ireps, registry, arg_types, annotations, integer_constants)

  known_owners = registry.values.flatten.map(&:owner).uniq
  class_annotations = ClassAnnotations.extract(ireps, registry, known_owners)
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
  warn '== known container-class constants (Array/Hash/Range-valued, whole program) =='
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
  class_layout_probe = ClassLayout.known(
    ClassLayout.analyze(ireps, registry, class_annotations, container_constants, annotated_array_return,
                        module_body_ivar_labels: module_body_ivar_labels)
  )
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
  CodeGen.embed_ivar_limits = BC2CPP_EMBED_IVAR_LIMITS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  return_names_probe = CodeGen.new(ireps, registry, ivar_layout, class_layout_probe, class_annotations,
                                    annotations, superclass_of, {}, {}, container_constants, {},
                                    Set.new, foreign_methods, nil, nil,
                                    analysis_only: true,
                                    native_expression_devirt: native_expression_devirt,
                                    native_registered_expressions: native_registered_expressions)
  array_return_probe = return_names_probe.array_return_names
  # RETCLASS_SELF_CALL_SUPPORT: from the same Level-0 probe as
  # array_return_probe (see ClassLayout.analyze's `ret_class_proof`).
  class_poison_reason = {}
  class_layout_raw = ClassLayout.analyze(ireps, registry, class_annotations, container_constants,
                                         annotated_array_return, poison_reason: class_poison_reason,
                                         array_ret_proof: ->(n) { array_return_probe.include?(n) },
                                         ret_class_proof: ->(n, o) { return_names_probe.class_return_for_self_call(n, o) },
                                         module_body_ivar_labels: module_body_ivar_labels)
  class_layout = ClassLayout.known(class_layout_raw)
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

  # ELEMENT_CLASS_SUPPORT: after ClassLayout (only proven-Array ivars are swept)
  # and ClassAnnotations (argument class hints are terminals).
  element_annotations = ElementAnnotations.extract(ireps, registry, known_owners)
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
  element_raw = ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                                           element_annotations, superclass_of,
                                           poison_reason: element_poison_reason)
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
  hash_element_raw = HashElementLayout.analyze(ireps, registry, class_layout, class_annotations,
                                               element_annotations, element_raw, superclass_of,
                                               poison_reason: hash_poison_reason)
  hash_element_layout = HashElementLayout.known(hash_element_raw)
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
  warn ''
  # BC2CPP_SELF_REGISTERING: same guard as for the probing CodeGen above.
  CodeGen.wired_embeddings = BC2CPP_WIRED_EMBEDDINGS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.embed_ivar_limits = BC2CPP_EMBED_IVAR_LIMITS unless ENV['BC2CPP_SELF_REGISTERING'] == '1'
  CodeGen.stable_class_constants = StableClassConstants.analyze(ireps, native_paths, foreign_ruby_srcs) |
                                    StableClassConstants.analyze_native(ireps, native_paths, foreign_ruby_srcs)
  warn "== stable class constants (CONST_SITE_CACHE): #{CodeGen.stable_class_constants.size} =="
  CodeGen.struct_members = struct_member_lists
  warn "== Struct.new owners with a known member list (STRUCT_INDEX_CACHE): #{CodeGen.struct_members.size} =="
  CodeGen.integer_constant_values = integer_constant_values
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
  fixnum_return_probe = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations,
                                    superclass_of, element_layout, element_annotations, container_constants,
                                    hash_element_layout, integer_constants, foreign_methods, outside_tokens,
                                    native_name_sources, included_modules, prepended_modules, unknown_mixins,
                                    analysis_only: :fixnum_return,
                                    native_expression_devirt: native_expression_devirt,
                                    native_registered_expressions: native_registered_expressions).fixnum_return_names
  ivar_layout = IvarLayout.analyze(ireps, registry, arg_types, annotations, integer_constants, fixnum_return_probe)
  warn ''
  warn '== ivar embedding =='
  if ivar_layout.empty?
    warn '  (none embeddable)'
  else
    ivar_layout.each do |klass, ivars|
      ivars.each { |name, type| warn "  EMBED  #{klass}#@#{name}  (#{type})" }
    end
  end

  # CLOSED_WORLD (docs/adr/0210): only for a build whose real gem list
  # (BC2CPP_BUILD_GEMS, from the compiled gem's own codegen task) passes
  # compiled_gems.rb's check; the scan reads that build's own sources.
  closed_world = nil
  if ENV['BC2CPP_CLOSED_WORLD'] == '1'
    repo_root = File.expand_path('../..', __dir__)
    build_name = ENV['BC2CPP_BUILD_NAME'].to_s
    build_gems = Shellwords.split(ENV['BC2CPP_BUILD_GEMS'].to_s).to_h { |kv| kv.split('=', 2) }
    errors = bc2cpp_closed_world_violations(build_name, build_gems, repo_root)
    abort "bc2cpp: BC2CPP_CLOSED_WORLD refused for build '#{build_name}':\n  #{errors.join("\n  ")}" unless errors.empty?

    outside_native, outside_ruby = bc2cpp_closed_world_outside_srcs(build_name, build_gems, repo_root)
    closed_world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked_ireps,
                                   native_paths: outside_native, ruby_paths: outside_ruby)
    warn "== closed world (#{build_name}: #{build_gems.size} gems, #{outside_native.size} native + " \
         "#{outside_ruby.size} Ruby outside sources) =="
    warn "  global refusal: #{closed_world.global_refusal || 'none'}"
    warn "  method_missing classes: #{closed_world.method_missing_classes.to_a.sort.join(', ')}"
    warn ''
  end

  gen = CodeGen.new(ireps, registry, ivar_layout, class_layout, class_annotations, annotations, superclass_of,
                    element_layout, element_annotations, container_constants, hash_element_layout,
                    integer_constants, foreign_methods, outside_tokens, native_name_sources,
                    included_modules, prepended_modules, unknown_mixins,
                    native_expression_devirt: native_expression_devirt,
                    native_registered_expressions: native_registered_expressions,
                    closed_world: closed_world)
  warn '== methods proven Fixnum-returning (FIXNUM_RETURN_PROOF) =='
  if gen.fixnum_return_names.empty?
    warn '  (none)'
  else
    gen.fixnum_return_names.sort.each { |n| warn "  RET #{n}" }
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
  # ONLY_OWNERS narrows emitted code (e.g. "LCF::File,LCF::Database"), not the
  # registry: srcs must still be the whole program (see compile_all).
  only_owners = ENV['ONLY_OWNERS']&.split(',')
  # OTHER_OWNERS: classes another gem's run compiles and exposes (with
  # OTHER_DECLS_HEADER); see compile_send.
  other_owners = ENV['OTHER_OWNERS']&.split(',')
  compiled = gen.compile_all(only_owners: only_owners, other_owners: other_owners)
  compiled += gen.emit_synthesized_accessors(only_owners: only_owners)

  # SKIP_UNSUPPORTED=1 drops methods containing `#error` from the output; they
  # stay interpreted. CLI exploration keeps the markers visible; real builds
  # (mrbgem.rake) set this, since a `#error` stops the C++ build.
  if ENV['SKIP_UNSUPPORTED'] == '1'
    skipped, compiled = compiled.partition { |m| m[:code].include?('#error') }
    unless skipped.empty?
      warn ''
      warn '== skipped (unsupported, left on the interpreter) =='
      skipped.each { |m| warn "  #{m[:owner]}##{m[:name]}" }
    end
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

  puts '#include <mruby.h>'
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
  # mrb_proc_new_cfunc for BLOCK_CFUNC_FALLBACK_SUPPORT; this header has a
  # C-linkage guard, so a plain #include is fine.
  puts '#include <mruby/proc.h>'
  # EXCEPTION_BREAK_SUPPORT: the exception a BLOCK_FALLBACK BREAK throws and the
  # call-site glue catches (mruby is built with MRB_USE_CXX_EXCEPTION). Always
  # emitted: a header-only struct with nothing to link.
  puts 'struct bc2cpp_block_break { mrb_value value; };'
  # EXCEPTION_RETURN_SUPPORT: a DIFFERENT type from bc2cpp_block_break, so the
  # method-level catch and the per-call-site catch never catch each other's
  # exception (exact C++ catch matching).
  puts 'struct bc2cpp_method_return { mrb_value value; };'
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
  CPP
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
      ~bc2cpp_ensure_guard() noexcept(false) {
        struct RObject* saved = M->exc;
        M->exc = NULL;
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
  # GETIDX's String arm calls mrb_str_aref (src/string.c, non-static), declared
  # only in mruby/internal.h, which has no C-linkage guard; including it would
  # give it C++ linkage and fail to link. So it is declared `extern "C"` here
  # with internal.h's signature.
  puts 'extern "C" mrb_value mrb_str_aref(mrb_state*, mrb_value, mrb_value, mrb_value);'
  # INTEGER_LSHIFT's kernel: exported by numeric.c but declared in no public header.
  puts 'extern "C" mrb_bool mrb_num_shift(mrb_state*, mrb_int, mrb_int, mrb_int*);'
  # DIV_FASTPATH_SUPPORT: same internal.h situation as mrb_str_aref.
  puts 'extern "C" mrb_value mrb_div_int_value(mrb_state*, mrb_int, mrb_int);'
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
  print gen.emit_const_lookup_helper
  print gen.emit_native_construct_decls
  print gen.emit_direct_construct_decls
  print gen.emit_forward_decls(compiled)
  print gen.emit_instance_tt_setup
  gen.reserve_poly_table_slots(compiled)
  print gen.emit_owner_class_cache
  print gen.emit_owner_registrations(compiled, BC2CPP_WIRED_EMBEDDINGS)
  print gen.emit_hot_only_registration_stubs(compiled, only_owners: only_owners)
  # SYMBOL_CACHE: rewrite every function first, so the table is complete before
  # it is printed ahead of the code that uses it.
  symbol_table = SymbolCache::Table.new
  compiled.each { |m| m[:code] = SymbolCache.rewrite(m[:code], symbol_table) }
  if closed_world
    kept = Hash.new(0)
    compiled.each { |m| m[:code].scan(%r{/\* CLOSED_WORLD kept: (\w+) \*/}) { |(r)| kept[r] += 1 } }
    converted = compiled.sum { |m| m[:code].scan(/\bbc2cpp_nomethod\(M,/).size }
    dropped = compiled.sum { |m| m[:code].scan(%r{^\s*// CLOSED_WORLD_SELF :}).size }
    warn "== closed world fallbacks: #{dropped} guards dropped, #{converted} bc2cpp_nomethod, " \
         "#{kept.values.sum} kept dispatching =="
    kept.sort_by { |r, n| [-n, r] }.each { |r, n| warn "  KEPT #{r}: #{n}" }
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
  end
  const_site_cache_code = SymbolCache.rewrite(gen.emit_const_site_cache, symbol_table)
  # OUTLINED_INDEX_OPS: after the symbol cache (their fallbacks become
  # bc2cpp_send too), ahead of every function that calls them.
  index_helpers_code = SymbolCache.rewrite(gen.emit_index_helpers(compiled), symbol_table)
  warn "== outlined index ops: #{gen.index_helper_site_counts(compiled).map { |k, n| "#{k} #{n}" }.join(', ')} sites =="
  warn ''
  poly_table_sites = gen.poly_table_site_counts(compiled)
  warn "== poly table dispatch: #{poly_table_sites.map { |t, n| "#{t} #{n}" }.join(', ').then { |s| s.empty? ? 'none' : s }} sites =="
  warn ''
  print SymbolCache.emit(symbol_table)
  print const_site_cache_code
  print index_helpers_code
  print gen.emit_poly_tables(compiled)
  compiled.each { |m| print m[:code] }

  # This run's cross-TU declarations header, for other gems'
  # OTHER_DECLS_HEADER (see emit_decls_header). Always written.
  File.write(File.join(out_dir, "#{symbol}_decls.h"), gen.emit_decls_header(compiled))

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
end
