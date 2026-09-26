# frozen_string_literal: true

# Construct, native-argument and super devirtualization targets.

# The typed-_impl calling convention models plain mandatory arguments only.
# ENTER's aspec is m1:opt:rest:m2:key:kwrest:block; anything past m1
# (`def foo(n = 0)`, `*args`, keywords, `&block`) does not fit, and reading
# only m1 once produced a direct call with an extra argument. Shared with
# report_annotation_candidates so it counts what drop_unsafe_embeddings would
# accept (see pure_mandatory_arity?).

# Native RGSS classes (mruby-rgss/src/lib.cxx DataType<T>) whose `SEND :new`
# can be devirtualized ("MONO :new -> direct native construct" in compile_send)
# when trace_new_target proves the receiver class: a hand-written lib.cxx entry
# point (`fn`) builds T from the argument registers, behind a runtime
# class-identity check against `class_fn` (see compile_send).
#
# `arity` must match the call site exactly (no default filling); an Array
# lists several accepted counts. Other counts fall back to dynamic dispatch.
# `arg_type` (:int/:float, uniform per class, matching the lib.cxx structs) is
# how each argument is unboxed before calling `fn`, which takes native
# mrb_int/mrb_float; mrb_as_int/mrb_as_float raise the same TypeError they
# raised inside `fn`.
NATIVE_CONSTRUCT_TARGETS = {
  'Tone' => { fn: 'rgss::tone_new_direct', class_fn: 'rgss::native_tone_class', arity: 4, arg_type: :float },
  'Color' => { fn: 'rgss::color_new_direct', class_fn: 'rgss::native_color_class', arity: 4, arg_type: :float },
  'Rect' => { fn: 'rgss::rect_new_direct', class_fn: 'rgss::native_rect_class', arity: 4, arg_type: :int },
  # Sprite: spr_init is `mrb_get_args(M, "|o", &vp)` plus a fixed body that
  # rgss::sprite_new_direct (include/rgss_construct.hxx) reproduces. "|o" never
  # coerces or raises, so there is no TypeError behavior to preserve.
  'Sprite' => { fn: 'rgss::sprite_new_direct', class_fn: 'rgss::native_sprite_class', arity: [0, 1],
                arg_type: :object },
  # Bitmap: bmp_init_size is `mrb_get_args(M, "ii", ...)` + alloc_obj, which
  # rgss::bitmap_new_direct reproduces. Bitmap#initialize also accepts a String
  # (file load), so `type_guard: :int` checks mrb_integer_p on every argument and
  # falls back to mrb_funcall otherwise.
  'Bitmap' => { fn: 'rgss::bitmap_new_direct', class_fn: 'rgss::native_bitmap_class', arity: 2, arg_type: :int,
                type_guard: :int },
}.freeze

# bc2cpp-COMPILED classes whose `Owner.new` may become bc2cpp_direct_alloc +
# the compiled `#initialize` _impl (emit_direct_construct_decls), the compiled
# counterpart of NATIVE_CONSTRUCT_TARGETS. The arity comes from the real
# #initialize and is re-checked at the call site; only the class-identity
# accessor is implied (`class_fn`-style, guarding a reassigned constant).
#
# Hand-listed, not derived from compiled_gems.rb owners: each entry needs a
# gem-init-captured RClass* and accessor function in that gem's register.cxx.
#
# Soundness bar for an entry, re-checked live by compile_send:
#   - no `self.new`/`self.allocate` anywhere for the class (checked against
#     @registry every run);
#   - #initialize compiles clean with pure mandatory arity
#     (pure_mandatory_arity?), or, for the keyword path, mandatory + optional
#     + keyword parameters (mandatory_optional_and_keyword_arity?,
#     compile_keyword_direct_construct);
#   - the call site's argument count matches.
# A site whose enclosing method does not compile is dropped with it
# (SKIP_UNSUPPORTED is per method), so an entry can be listed with no active
# site. #initialize is always private (src/class.c), which does not matter: a
# direct call bypasses the visibility lookup, as Class#new does.
# Receivers written relative to the enclosing module (`Scene::Map` inside
# `module RPG2k`) are resolved by lexically_resolve_construct_target, which
# only returns members of this table and refuses cross-level ambiguity.
# Classes whose #initialize has `= default` arguments and no keywords
# (Game::Vehicle, Game::Character, ...) are omitted: they could never fire.
DIRECT_CONSTRUCT_TARGETS = %w[Game::Transition Game::Map
                               Game::Switches Game::Timer Game::MessageConfig
                               Game::Screen Game::ChipSet Game::Interpreter
                               RPG2k::Scene::Menu RPG2k::Scene::DebugMenu
                               RPG2k::Scene::ItemMenu Game::NumberInput
                               Game::MoveRoute RPG2k::Scene::Map
                               RPG2k::Scene::MapViewer
                               RPG2k::Scene::ChipsetEditor
                               Game::Battle].freeze

# NATIVE_ARG_TARGETS (the Set after sanitize_c_ident below): human-vetted
# "Owner#name" allowlist that moves a compiled method's mandatory argument
# from mrb_value to a native mrb_int/mrb_sym parameter. A position is retyped
# only when BOTH the method is listed AND its own `# bc2cpp: (fixnum, ...)`
# annotation (never ArgTypes inference) names fixnum/symbol there. Annotations
# alone would be sound (a wrong one raises TypeError), but the native entry
# unboxes with mrb_get_args("i")/mrb_as_int, which raise on nil, so each entry
# must meet this bar:
#   - no nil-guard on the annotated position (`id.nil? || ...`, `x && x > 0`):
#     such a body tolerates nil today and would start raising
#     (Game::Actor#knows_skill?/#learn_skill, Game::EnemyAi#enemy and
#     RPG2k::Scene::Base#value_font_color are excluded for this);
#   - either the position already raises on a non-Integer (unguarded
#     arithmetic/comparison, so only the exception class changes), or every
#     real caller was traced to a provably Integer/Symbol value (needed for
#     "assign-only" bodies like `@x = x`);
#   - the method compiles clean with pure mandatory arity; otherwise there is
#     no `_impl` to retype and the entry is moot. Check the generated BODY,
#     not just the signature: the `_impl` signature is printed even when the
#     body is all `#error` lines;
#   - the class is not in DIRECT_CONSTRUCT_TARGETS, whose construct path
#     passes mrb_value arguments to `#initialize` and would desync from a
#     retyped signature.
# Unresolved nil paths were excluded rather than guessed (Game::State#
# initialize: SAVE_MOVABLE map_id/x/y have no schema default; Game::Interpreter
# #apply: `when 0 then val` returns operand_value unguarded;
# Game::Interpreter#resume_battle: battle.result may still be nil in
# leave_battle_event_phase).
#
# CPP_RESERVED_WORDS: a Ruby parameter name can be a C++ keyword
# (RPG2k::Scene::Map#page_field(name, default)). Not a full keyword table,
# just plausible names; every arg_names entry goes through sanitize_c_ident.
CPP_RESERVED_WORDS = Set[
  'default', 'class', 'new', 'delete', 'template', 'namespace', 'operator',
  'this', 'true', 'false', 'nullptr', 'try', 'catch', 'throw', 'const',
  'static', 'struct', 'union', 'enum', 'typedef', 'sizeof', 'goto',
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'break', 'continue',
  'return', 'void', 'int', 'float', 'double', 'char', 'bool', 'long',
  'short', 'auto', 'extern', 'volatile', 'explicit', 'typename', 'using',
  'public', 'private', 'protected', 'virtual', 'friend', 'export', 'mutable',
].freeze

def sanitize_c_ident(name)
  CPP_RESERVED_WORDS.include?(name) ? "#{name}_" : name
end

NATIVE_ARG_TARGETS = Set[
  'Game::Actor#gain_exp',
  'Game::Actor#change_level_by',
  'Game::Actor#change_mp',
  'Game::Actor#exp_for_level',
  'Game::Actor#free_two_handed_slot',
  'Game::Actor#slot_cursed?',
  'Game::Actor#base_param_limit',
  'Game::Actor#unequip',
  'Game::Actor#base_stats',
  'Game::Actor#change_param',
  'Game::Actor#change_class',
  'Game::Actor#battle_row=',
  'Game::Map#in_bounds?',
  'Game::Map#substitute_tile',
  'Game::Map#set_tile',
  'Game::Map#tile',
  'Game::Transition#half',
  'Game::Transition#block_count_through',
  'Game::Screen#tint_to',
  'Game::Screen#restore_tint',
  'Game::Screen#shake',
  'Game::Screen#flash',
  'Game::Screen#approach',
  'Game::State#set_screen_transition',
  'Game::Interpreter#character_ref',
  'Game::Interpreter#trunc_div',
  'Game::Interpreter#skip_to',
  'Game::Interpreter#find_choice_option',
  'Game::Interpreter#do_control_vars_range_variable',
  'Game::Interpreter#vehicle_operand',
  'Game::Interpreter#screen_operand',
  'Game::Interpreter#queue_level_up_messages',
  'Game::Interpreter#trunc_mod',
  'LCF::EventCommand#initialize',
  'LCF::MoveCommand#initialize',
  'RPG2k::Scene::SaveLoad#move_selection',
  'RPG2k::Scene::Title#move_selection',
  'RPG2k::Scene::ItemMenu#move_item_cursor',
  'RPG2k::Scene::ItemMenu#move_teleport_cursor',
  'RPG2k::Scene::Order#move_cursor',
  'RPG2k::Scene::Map::LRUBitmapCache#initialize',
  'RPG2k::Scene::SaveLoad#draw_slot_label',
  'RPG2k::Scene::Base#draw_stat_segment',
  'RPG2k::Scene::Base#sticky_list_top',
  'RPG2k::Scene::SaveLoad#build_arrow_sprite',
  'RPG2k::Scene::Menu#wait_term_for',
  'RPG2k::Scene::Menu#enter_actor_selection',
  'RPG2k::Scene::VehicleWorld#initialize',
  'RPG2k::Scene::Battle#battler_z',
  'RPG2k::Scene::Battle#actor_sprite_z',
  'RPG2k::Scene::Battle#battle_grid_position',
  'RPG2k::Scene::Battle#move_battle_target_cursor',
  'RPG2k::Scene::Battle#move_battle_list_index',
  'RPG2k::Scene::Battle#battle_skill_unavailable?',
  'RPG2k::Scene::Battle#draw_gauge_system2',
  'RPG2k::Scene::Battle#draw_number_system2',
  'RPG2k::Scene::Battle#refresh_battle_list_arrows',
].freeze

# SUPER_SUPPORT (ADR 0146): human-vetted "Owner#name" allowlist for compiling
# `super`/`super(...)`, because soundness depends on whole-program facts
# compile_insn cannot re-derive per site:
#   - Block forwarding: OP_SUPER always forwards the current method's block
#     (vm.c L_SENDB_SYM; OP_SUPER is not in the SET_NIL_VALUE(regs[new_bidx])
#     list), but a compiled `_impl` has no block parameter, so the forwarded
#     block is nil. That is correct only if no caller of the listed method
#     ever passes a block. Re-check this for every new entry.
#   - No include/prepend between the caller and the superclass: OP_SUPER
#     follows CI_TARGET_CLASS(ci - 1)->super, which passes through an ICLASS
#     per included module, so a module's same-named method would win over
#     "jump to @superclass_of". Now also checked mechanically (ADR 0158).
#   - The target must compile clean (super_target gates on compiles_clean?).
# Supported shapes: `super parent` (SUPER n=1 into RPG2k::Scene::Base#
# initialize) and bare `super` in a zero-parameter method (SUPER n=0).
# Not here: `super` into a native method (RGSS::Bitmap::LoadError#initialize,
# Object#method_missing/#respond_to_missing? on LCF::Sections/Array1D/File):
# there is no bytecode `_impl` to call; see ZSUPER_NATIVE_TARGETS for those.
# A zsuper in a method with parameters (`ARGARY` + `SUPER n=*`) is the other
# shape, not matched by the `n=(\d+)` parse (ADR 0159).
SUPER_TARGETS = Set[
  'RPG2k::Scene::Battle#initialize',
  'RPG2k::Scene::DebugMenu#initialize',
  'RPG2k::Scene::ItemMenu#initialize',
  'RPG2k::Scene::Menu#initialize',
  'RPG2k::Scene::ChipsetEditor#initialize',
  'RPG2k::Scene::EquipMenu#initialize',
  'RPG2k::Scene::GameOver#initialize',
  'RPG2k::Scene::MapViewer#initialize',
  'RPG2k::Scene::Order#initialize',
  'RPG2k::Scene::SkillMenu#initialize',
  'RPG2k::Scene::StatusMenu#initialize',
  'RPG2k::Scene::Title#initialize',
  'RPG2k3::Scene::Battle#update',
  'RPG2k3::Scene::Battle#drive_battle_command',
  'RPG2k3::Scene::Battle#enter_command_phase',
  'RPG2k3::Scene::Battle#open_battle_options',
  'RPG2k3::Scene::Battle#advance_actor',
  'RPG2k3::Scene::Battle#prev_commandable_actor_index',
  'RPG2k::Scene::Map#initialize',
  'RPG2k::Scene::SaveLoad#initialize',
  'RPG2k3::Scene::Battle#finish_round_animation',

  # tools/optcarrot_probe's separate closed world (see its README.md); inert for
  # real gem builds. Bare `super` (SUPER R2 n=0) into Optcarrot::APU::Oscillator;
  # no caller passes a block and no include intervenes. #initialize/#poke_0/
  # #poke_3 are `SUPER n=*` zsupers, not this shape.
  'Optcarrot::APU::Pulse#reset',
  'Optcarrot::APU::Pulse#active?',
  'Optcarrot::APU::Triangle#reset',
  'Optcarrot::APU::Triangle#active?',
  'Optcarrot::APU::Noise#reset',
].freeze

# ---------------------------------------------------------------------------
# ZSUPER_NATIVE_SUPPORT: a bare `super` in a method WITH parameters, reaching a
# native mruby method. mrbc's codegen_zsuper emits:
#
#     ARGARY  R(a+1)  m1:r:m2:lv (kd)      ; this method's arguments as an Array
#     SUPER   R(a)    n=*                  ; forward that Array as the arg list
#
# super_target cannot help (no bytecode `_impl`), so the two native targets are
# reproduced exactly:
#
#   * Object#respond_to_missing? is Kernel's ROM entry `mrb_false`
#     (src/kernel.c): `return mrb_false_value();`, ignoring self and arguments.
#     It is `static`, so the body is reproduced, not called.
#
#   * Object#method_missing is BasicObject's `mrb_obj_missing` (src/class.c).
#     It reads its arguments via mrb_get_args off the current ci frame, which
#     only VM dispatch sets up, so it cannot be called directly (the same
#     hazard as extract_native_method_names). It only tail-calls
#     `mrb_method_missing(mrb, name, self, args)` (mruby/internal.h), which
#     takes plain C parameters, so that is called with the same values:
#       - name = mrb_obj_to_sym(first argument): what mrb_get_args "n" does
#         (it accepts a String too, unlike mrb_symbol());
#       - args = a fresh Array copy of the remaining arguments, matching
#         mrb_ary_new_from_values: the array is stored in the exception's @args
#         (src/error.c), so aliasing the method's own *args would be observable.
#     mrb_method_missing has no C-linkage guard, so it is declared `extern "C"`
#     in the generated prologue.
#
# Divergence: the interpreter pushes a cfunc frame and mrb_obj_missing zeroes
# its mid; the only consumer of mid there is pack_backtrace (src/backtrace.c),
# which skips cfunc frames with mid == 0, so having no frame gives the same
# backtrace.
#
# Dropping ARGARY/SUPER is sound (vm.c): ARGARY (lv == 0) only builds the Array
# and raises only for "super called outside of method", impossible in a def
# body. SUPER raises only for that, a prepended/module target class, or a self
# not kind_of its own class. check_argument_count cannot raise:
# method_missing is MRB_ARGS_ANY(), and respond_to_missing? is
# MRB_ARGS_ARG(1,1) against an ARGARY spec of 2:0:0:0 (exactly 2 values).
# OP_SUPER skips the visibility check, so MRB_MT_PRIVATE is inert.
#
# This table carries the hand-verified remainder zsuper_native_kind cannot
# derive (see its comment for what it re-checks per site): the closed world
# has three `include`s (Enumerable in LCF::Array2D and Game::Party, `class
# Object; include RGSS; end`) and no `prepend`, so each listed owner's chain is
# Owner -> Object -> ICLASS(RGSS) -> ICLASS(Kernel) -> BasicObject, none with a
# Ruby definition of either name. zsuper_native_kind re-checks that exactly
# one native source defines each name (extract_native_method_sources).
ZSUPER_NATIVE_TARGETS = {
  'LCF::Sections#respond_to_missing?' => :kernel_respond_to_missing,
  'LCF::Array1D#respond_to_missing?' => :kernel_respond_to_missing,
  'LCF::File#respond_to_missing?' => :kernel_respond_to_missing,
  'LCF::Sections#method_missing' => :basic_object_method_missing,
}.freeze

# Per kind: the method name, the ARGARY operand spec mrbc must have emitted,
# and the single NATIVE_SRCS file that must be the only native definer of the
# name. zsuper_native_kind re-checks all three per site; any mismatch keeps the
# `#error`.
ZSUPER_NATIVE_SHAPES = {
  # `def respond_to_missing? sym, include_private = false` -> ENTER 1:1:...,
  # zsuper rebuilds both positional slots: m1=2, r=0, m2=0, kd=0, lv=0.
  kernel_respond_to_missing: {
    name: 'respond_to_missing?',
    argary: '2:0:0:0',
    native_src: '3rd/mruby/src/kernel.c',
  }.freeze,
  # `def method_missing sym, *args` -> ENTER 1:0:1:..., m1=1, r=1: the array is
  # `[sym, *args]` (vm.c OP_ARGARY copies m1 values, then splices the rest), the
  # same split mrb_obj_missing's `mrb_get_args(mrb, "n*!", ...)` performs.
  basic_object_method_missing: {
    name: 'method_missing',
    argary: '1:1:0:0',
    native_src: '3rd/mruby/src/class.c',
  }.freeze,
}.freeze

# Owners on every listed owner's chain whose Ruby definition of the name would
# intercept `super`. Modules cannot be listed (they can be included anywhere);
# zsuper_native_kind refuses any owner missing from `superclass_of`, which
# only real CLASS opcodes populate, so modules and singletons are excluded.
ZSUPER_NATIVE_BLOCKED_OWNERS = %w[Object Kernel BasicObject].freeze

# Call-site devirtualization: is THIS receiver provably an instance of one
# exact class? Unlike monomorphic_target this can resolve a POLY name.
# Walks back from `idx` for the last writer of `reg` (following MOVEs) to a
# `Klass.new(...)` SEND, then through the GETMCNST/GETCONST chain on the same
# register (each segment overwrites it in place) to a `::`-joined name spelled
# like MethodDef#owner. `Klass.new` always allocates exactly Klass, so no
# inheritance model is needed. Anything unrecognized returns nil (dynamic
# dispatch).
# Optional extra terminals: `ivar_classes` (ClassLayout, this owner) and
# `arg_classes` (ClassAnnotations). `resolving_new:` starts inside the SEND
# :new case, to resolve that call's own receiver (NATIVE_CONSTRUCT_TARGETS).
# CHAINED_ACCESSOR_SUPPORT: with `class_layout` (all owners) and `registry`, a
# mid-chain SEND (`@state.screen.foo`) resolves when its receiver traces to
# class R (recursing on a strictly smaller index), R defines the name as an
# :ivar_accessor getter, and R's class_layout entry names that ivar's class.
# Every consumer still guards these hints with mrb_obj_class.
# LEXICAL_NEW_TARGET_RESOLUTION: map the constant path a `.new` site WRITES
# (`Scene::MapViewer` inside `module RPG2k`, or a bare `Switches`) to the
# registry name, using Module.nesting:
#
#     module RPG2k; module Scene; class DebugMenu
#       def f; Scene::MapViewer.new; end
#     end; end; end
#
#   Module.nesting there is [RPG2k::Scene::DebugMenu, RPG2k::Scene, RPG2k]:
#   the owner's name prefixes, innermost first; the first prefix that holds
#   the first segment wins. `Scene::Battle` inside `module RPG2k3` resolves to
#   RPG2k3::Scene::Battle, never RPG2k's.
# Owner prefixes equal Module.nesting only for nested (not compact `class
# A::B`) definitions; the closed world has no compact ones. Lexical scope only;
# the cref's ancestors are not searched.
# Soundness: only returns an existing DIRECT_CONSTRUCT_TARGETS entry; a match
# at more than one level is ambiguous and returns nil; no owner returns nil;
# nil falls back to the written path (dynamic dispatch / `#error`).
def lexically_resolve_construct_target(written, owner)
  return nil if written.nil? || written.empty?
  return nil if owner.nil?

  nesting = owner.to_s.sub(/\.singleton\z/, '').split('::')
  return nil if nesting.empty?

  hits = []
  nesting.length.downto(1) do |n|
    candidate = "#{nesting.first(n).join('::')}::#{written}"
    hits << candidate if DIRECT_CONSTRUCT_TARGETS.include?(candidate)
  end

  # Ambiguous across nesting levels: refuse (see above).
  return nil if hits.length > 1

  hits.first
end

# `dominated:` (RETURN-site proofs only): `->(w_idx, use_idx, reg)` that must
# accept every hop, so no hop can skip past a join (ADR 0198).
def trace_new_target(irep, idx, reg, ivar_classes = nil, mand = 0, arg_classes = nil, resolving_new: false, owner: nil,
                      class_layout: nil, registry: nil, container_constants: nil, element_annotations: nil,
                      known_owners: nil, capture_hints: nil, ret_class_proof: nil, dominated: nil, canonical: true)
  path = []
  use = idx
  # GETCONST/GETMCNST are class-name evidence only while resolving a `.new`
  # receiver: `@position = POS_BOTTOM` is an Integer constant, not a class.
  # `resolving_new` becomes true right after a SEND :new (with an empty `path`),
  # or starts true for the `resolving_new:` caller.
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]

    if insn.op == 'RESCUE'
      # RESCUE_DUAL_REGISTER_SUPPORT: `R[b] = R[a].isa?(R[b])` (see
      # IvarLayout.trace_type's RESCUE arm): `b`, the SECOND token, is a write.
      # Checked before the `d == reg` filter, which only reads the first token and
      # would otherwise treat the instruction as not touching `reg`.
      a, b = insn.args.scan(/R(\d+)/).flatten
      next unless [a, b].include?(reg)
      return nil if b == reg

      next
    end

    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    if dominated && !READ_ONLY_OPCODE_SKIP.include?(insn.op)
      return nil unless dominated.call(i, use, reg)

      use = i
    end

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'GETIDX', 'GETIDX0'
      return nil unless element_annotations && class_layout && registry

      # GETIDX overwrites its receiver register; GETIDX0 has a separate source.
      recv_reg = if insn.op == 'GETIDX'
                   reg
                 else
                   insn.args.scan(/R(\d+)/).flatten[1]
                 end
      return nil unless recv_reg

      recv_class = trace_new_target(irep, i, recv_reg, ivar_classes, mand, arg_classes, owner: owner,
                                     class_layout: class_layout, registry: registry,
                                     container_constants: container_constants,
                                     element_annotations: element_annotations,
                                     known_owners: known_owners, capture_hints: capture_hints,
                                     ret_class_proof: ret_class_proof, dominated: dominated, canonical: canonical)
      # An annotated Hash<Klass> parameter is a safe source for indexed values.
      # Only plain MOVE aliases back to the untouched argument register count;
      # GETIDX keeps its Hash and subclass dispatch guards at codegen.
      arg_reg = recv_reg
      captured_reg = nil
      (i - 1).downto(0) do |j|
        prior = irep.instructions[j]
        next unless prior.args[/^R(\d+)/, 1] == arg_reg
        if prior.op == 'MOVE'
          arg_reg = prior.args.scan(/R(\d+)/).flatten[1]
          break unless arg_reg
        else
          upvar = prior.args.split(/\s+/) if prior.op == 'GETUPVAR'
          captured_reg = prior.args[/^R(\d+)/, 1].to_i if upvar && upvar[2] == '0'
          arg_reg = nil
          break
        end
      end
      # The trace can stop at a block's GETUPVAR before reaching the captured
      # container; the callsite hint is limited to annotated Hash arguments.
      recv_class ||= capture_hints&.dig(irep.label, captured_reg, :container_class) if captured_reg
      recv_class = resolve_owner_name(recv_class, { owner: owner, known_owners: known_owners }) if known_owners
      arg_pos = arg_reg&.to_i
      if recv_class == 'Hash' && arg_pos && arg_pos.between?(1, mand) &&
         element_annotations[irep.label]&.arg_containers&.[](arg_pos - 1) == 'Hash'
        annotated_value = element_annotations[irep.label]&.arg_elements&.[](arg_pos - 1)
        return annotated_value if annotated_value
      end
      if recv_class == 'Hash' && captured_reg
        captured_value = capture_hints&.dig(irep.label, captured_reg, :element_class)
        return captured_value if captured_value
      end
      md = registry['[]']&.find { |candidate| candidate.owner == recv_class && candidate.irep }
      return md && element_annotations[md.irep]&.ret_class
    when 'SEND0', 'SEND'
      return nil if resolving_new || !path.empty?

      # Same charset as compile_send's name extraction.
      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      if name == 'new'
        resolving_new = true
      elsif name == 'dup' && registry && (registry['dup'] || []).all? { |md| md.owner == '<native>' }
        # DUP_PRESERVES_CLASS: a blockless, argless `.dup` returns an object of exactly
        # its receiver's class: mrb_obj_dup (src/class.c) does
        # `mrb_obj_alloc(mrb, mrb_type(obj), mrb_obj_class(mrb, obj))`, bound as
        # Kernel#dup with MRB_ARGS_NONE (src/kernel.c). The `registry['dup']` check
        # above rejects any program-level `def dup`. So the receiver's class (traced by
        # recursion on a strictly smaller index; SEND overwrites its receiver register)
        # is the result's class.
        # SEND0 prints no `n=`; a `.dup(x)` with arguments is an ArgumentError and
        # proves nothing.
        n_match = insn.args.match(/n=(\d+|\*)/)
        return nil if n_match && n_match[1] != '0'

        return trace_new_target(irep, i, reg, ivar_classes, mand, arg_classes, owner: owner,
                                 class_layout: class_layout, registry: registry,
                                 container_constants: container_constants,
                                 element_annotations: element_annotations,
                                 known_owners: known_owners, capture_hints: capture_hints,
                                 ret_class_proof: ret_class_proof, dominated: dominated, canonical: canonical)
      else
        # CHAINED_ACCESSOR_SUPPORT (see the header): a non-`new` SEND may be a chained
        # :ivar_accessor read. A no-op unless the caller passes class_layout and
        # registry; `resolving_new` callers already returned above.
        return nil unless class_layout && registry

        # attr_reader takes zero arguments (src/class.c), so require n=0 to rule out a
        # same-named POLY method of another arity (as the MONO/TYPED arity guards do).
        # SEND0 prints no "n=" (vm.c OP_SEND0 has c=0).
        # The receiver is whatever wrote `reg` before `i` (SEND overwrites its
        # receiver register in place); recursing on a strictly smaller index
        # terminates.
        recv_class = trace_new_target(irep, i, reg, ivar_classes, mand, arg_classes, owner: owner,
                                       class_layout: class_layout, registry: registry,
                                       container_constants: container_constants,
                                       element_annotations: element_annotations,
                                       known_owners: known_owners, capture_hints: capture_hints,
                                       ret_class_proof: ret_class_proof, dominated: dominated, canonical: canonical)
        return nil unless recv_class
        recv_class = resolve_owner_name(recv_class, { owner: owner, known_owners: known_owners }) if known_owners

        if element_annotations
          annotated = registry[name]&.find do |md|
            md.owner == recv_class && md.irep && element_annotations[md.irep]&.ret_class
          end
          return element_annotations[annotated.irep].ret_class if annotated
        end

        n_match = insn.args.match(/n=(\d+|\*)/)
        return nil if n_match && n_match[1] != '0'

        # An attr_writer is registered as "name=", so `registry[name]` only matches
        # getters.
        accessor = registry[name]&.find { |md| md.owner == recv_class && md.kind == :ivar_accessor }
        return nil unless accessor

        # R's own hint for this ivar (getter name == ivar name). class_layout can be
        # ClassLayout.analyze's in-progress table, so never return UNKNOWN from it.
        # `key?`, not `[]`: the table is `Hash.new { |h, k| h[k] = {} }`, and `[]`
        # would insert entries and reorder the `== known-ivar-class hints ==`
        # diagnostic.
        recv_ivars = class_layout[recv_class] if class_layout.key?(recv_class)
        hint = recv_ivars && recv_ivars[name]
        return nil unless hint && hint != ClassLayout::UNKNOWN

        return hint
      end
    when 'SSEND0', 'SSEND'
      # RETCLASS_SELF_CALL_SUPPORT: an implicit-receiver call has no receiver
      # register (and a bare `new(...)` here is an instance method, not Class#new),
      # so the only evidence is `ret_class_proof` (compute_class_return_names); nil
      # for callers that do not opt in. Never contributes to a `.new` path.
      return nil if resolving_new || !path.empty?
      return nil unless ret_class_proof

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless name

      # Explicit `return`: this is inside the downto block, so a bare expression
      # would only end this iteration and the walk would continue past the answer.
      # `owner`: CodeGen#self_call_reaches_def? (never method_missing).
      return ret_class_proof.call(name, owner)
    when 'SENDB'
      # BLOCK_CARRYING_NEW: `Klass.new(...) { ... }` compiles to SENDB. A block
      # passed to #initialize does not change which class `.new` allocates, so set
      # `resolving_new` like the blockless case and share the GETCONST walk.
      # SSENDB (`self.new { }`) is excluded: self's class is not a fixed name, and
      # no such site exists.
      return nil if resolving_new || !path.empty?

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless name == 'new'

      resolving_new = true
    # Same register: SEND overwrites its receiver register with the result.
    when 'GETIV'
      return nil if resolving_new || !path.empty?

      ivar = insn.args[/@(\w+)/, 1]
      klass = ivar_classes && ivar_classes[ivar]
      return known_owners ? resolve_owner_name(klass, { owner: owner, known_owners: known_owners }) : klass
    when 'GETUPVAR'
      return nil if resolving_new || !path.empty?

      dst, _upvar, level = insn.args.split(/\s+/)
      return nil unless level == '0'

      capture_class = capture_hints&.dig(irep.label, dst[/\d+/].to_i, :container_class)
      capture_class
    when 'ARRAY', 'ARRAY2'
      # EACH_BLOCK_SUPPORT: an ARRAY literal is always an Array (vm.c OP_ARRAY). Only
      # valid at the end of a trace: during a `.new` chain or constant path the
      # register belongs to another expression.
      return nil if resolving_new || !path.empty?

      return 'Array'
    when 'HASH'
      # HASH_EACH_SUPPORT: a HASH literal is always a Hash (vm.c OP_HASH); same
      # end-of-trace gating.
      return nil if resolving_new || !path.empty?

      return 'Hash'
    when 'RANGE_INC', 'RANGE_EXC'
      # INTERP_UNLOCK: RANGE_INC/RANGE_EXC always create a Range (vm.c,
      # mrb_range_new); same end-of-trace gating.
      return nil if resolving_new || !path.empty?

      return 'Range'
    when 'GETMCNST'
      # CONST_CONTAINER_SUPPORT: collecting a segment is harmless either way; what
      # happens with `path` is decided at GETCONST.
      # Not `$`-anchored: a trailing "; R6:name" comment would end up in the segment.
      path.unshift(insn.args[/::(\w+)/, 1])
    when 'GETCONST'
      # "GETCONST R4 Integer" or "GETCONST R3 MAX_DIGITS\t; R3:d": \S+ stops before
      # the local-name comment.
      const_name = insn.args[/^R\d+\s+(\S+)/, 1]

      # CONST_CONTAINER_SUPPORT: without `resolving_new` this chain is the receiver
      # of an ordinary call (`Game::Vehicle::TYPES.each`), and the useful fact is
      # "this constant's value is a proven Array/Hash" from build_registry's
      # `container_constants`, keyed by `[const_name] + path` (root first).
      unless resolving_new
        return nil unless container_constants

        unless path.empty?
          full = ([const_name] + path).join('::')
          return container_constants[full]
        end

        # A bare reference (`STAT_NAMES.each`): lexical lookup innermost first against
        # `container_constants`; absent everywhere means nil.
        if owner
          nesting = owner.to_s.sub(/\.singleton\z/, '').split('::')
          nesting.length.downto(1) do |n|
            candidate = "#{nesting.first(n).join('::')}::#{const_name}"
            return container_constants[candidate] if container_constants.key?(candidate)
          end
        end
        return container_constants[const_name]
      end

      # Resolve the written path (bare `Switches` or qualified `Scene::MapViewer`)
      # with lexically_resolve_construct_target (see its comment): innermost first,
      # DIRECT_CONSTRUCT_TARGETS members only, ambiguity refused. A general lookup
      # is not sound here: Ruby may fall through to a same-named top-level constant,
      # which this function cannot rule out. A miss falls back to the written path;
      # an already-qualified `Game::Transition` resolves through that fallback.
      # Consumers also guard with `mrb_class_ptr(recv) == ...` at runtime, but this
      # does not rely on it.
      written = ([const_name] + path).join('::')
      resolved = lexically_resolve_construct_target(written, owner)
      return resolved if resolved
      # UNIQUE_CLASS_NAME: construct-target callers (canonical: false) key their
      # tables by the written name.
      if canonical && path.empty? && (unique = UniqueClassNames.resolve(const_name, owner))
        return unique
      end

      path.unshift(const_name)
      return path.join('::')
    when 'JMPNOT', 'JMPIF'
      # CONTAINER_PHI_MERGE: `x || []` / `x && {}` writes a container literal
      # into `reg` on ONE side of the branch, so the register has two incoming
      # definitions and the walk would otherwise keep going past the literal
      # to an older, unrelated write (or off the top of the body to the
      # argument). ADR 0191 added this opcode to READ_ONLY_OPCODE_SKIP, which is
      # correct for soundness of the skip but loses the literal: ADR 0191
      # verified that had zero measurable effect, because no `x || []` receiver
      # was reachable then.
      #
      # The merge is admitted ONLY when the other (branch-taken) side is
      # provably the same container class, or provably nil:
      #   * LOADNIL, so the two arms are `nil` and the literal;
      #   * another literal of the same class, so both arms agree.
      # Anything else -- a GETIV with no class fact, an opaque SEND result, a
      # GETIDX whose element class is unresolved -- is REFUSED, not merged.
      # That is the whole safety argument, and it matters more here than in the
      # TYPED send path: this fact feeds the block recognizers' `traced ==
      # 'Array'` GATE, which has no runtime fallback (a wrong fact emits a loop
      # over a register that is not an Array), so a wrong merge would not
      # degrade to mrb_funcall as a wrong TYPED fact does.
      merged = container_phi_merge(irep, i, reg)
      return merged if merged

      # Unproven: fall through to the READ_ONLY_OPCODE_SKIP behaviour ADR 0191
      # established, which is to keep walking backwards past this read.
    when *READ_ONLY_OPCODE_SKIP
      # READ_ONLY_OPCODE_SKIP (ClassLayout counterpart; ADR 0188, ADR 0191): skip
      # opcodes that only read their `R%d` operand, as IvarLayout.trace_type does.
      # RESCUE is handled above the register filter instead.
    else
      return nil
    end
  end
  # Never written: an incoming argument (register N is argument N for N <=
  # mand). Only a class annotation can name its class; pooling call sites is
  # unsound for POLY names.
  return nil if dominated && !dominated.call(-1, use, reg)

  pos = reg.to_i
  return arg_classes[pos - 1] if arg_classes && pos.between?(1, mand)

  nil
end

# CONTAINER_PHI_MERGE: the class a register provably holds across a
# `JMPNOT`/`JMPIF` that has a container literal on its fall-through arm, or nil
# when the other arm is not provably the same class (or nil).
#
# `at` is the branch instruction's index; `reg` the branch's operand. The
# literal is the instruction immediately after it. The value the jump KEEPS is
# whatever wrote `reg` earlier, so that older writer is the side that has to
# agree, and proving it is the deliberately conservative half of this rule.
#
# Soundness matters more here than in the TYPED send path. A TYPED fact is
# checked at runtime (`mrb_obj_class(M, recv) == owner_class_ptr`) and a wrong
# one costs a failed compare; the block recognizers instead GATE on
# `traced == 'Array'` and then emit `RARRAY_LEN`/`RARRAY_PTR` with no runtime
# check at all. So this returns a class only when the register cannot hold
# anything but that container class or nil at the merge point:
#   * LOADNIL -- the other arm is nil, which no inlined receiver ever is;
#   * a literal of the SAME class -- both arms agree.
# An older GETIV with no class fact, an opaque SEND result, or a GETIDX whose
# element class is unresolved is refused, not merged.
def container_phi_merge(irep, at, reg)
  lit = irep.instructions[at + 1]
  return nil unless lit && %w[ARRAY ARRAY2 HASH].include?(lit.op) && lit.args[/^R(\d+)/, 1] == reg

  lit_class = lit.op == 'HASH' ? 'Hash' : 'Array'
  (at - 1).downto(0) do |i|
    insn = irep.instructions[i]
    next unless insn.args[/^R(\d+)/, 1] == reg

    case insn.op
    when 'MOVE'
      src = insn.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    when 'LOADNIL'
      return lit_class
    when 'ARRAY', 'ARRAY2'
      return 'Array' if lit_class == 'Array'
    when 'HASH'
      return 'Hash' if lit_class == 'Hash'
    end
    return nil
  end
  nil
end

# NIL_TOLERANT_JOIN predicate: true only when `reg` at `idx` was just loaded by
# LOADNIL (following MOVEs). A false negative only falls back to the ordinary
# join; a false positive would drop real evidence.
def nil_literal_write?(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADNIL'
      return true
    else
      return false
    end
  end
  false
end

# CONST_CONTAINER_SUPPORT predicate: `reg` at `idx` is a fresh
# Array/Hash/Range literal, optionally followed by exactly one `.freeze` on the
# same register (`ARRAY R1 2` / `SEND0 R1 :freeze` / `SETCONST NAME R1`).
# `.freeze` is accepted only directly on such a literal, never as a general
# passthrough: RGSS::Transition#freeze is an unrelated override with a
# different return value.
def literal_container_class(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'SEND0'
      return nil unless insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == 'freeze'
    when 'ARRAY', 'ARRAY2'
      return 'Array'
    when 'HASH'
      return 'Hash'
    when 'RANGE_INC', 'RANGE_EXC'
      return 'Range'
    else
      return nil
    end
  end
  nil
end

# LITERAL_EQQ_SUPPORT: find a literal Fixnum/Symbol written to a `:===`
# receiver register, the `case x; when 5; when :bar` desugaring:
#   LOADI_5  R4  (5)
#   MOVE     R5  R3   ; R3 holds the case value
#   SEND     R4  :===  n=1
#   ...
#   LOADSYM  R4  :bar
#   MOVE     R5  R3
#   SEND     R4  :===  n=1
# Separate from trace_new_target: a different question with no shared
# terminals. Follows MOVEs defensively. Returns {type: :fixnum, value: "5"} /
# {type: :symbol, name: "bar"}, or nil (compile_send keeps POLY dispatch).
def trace_eqq_literal_receiver(irep, idx, reg)
  (idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADSYM'
      # Same extraction as LOADSYM's codegen (stops before a local-name comment).
      name = insn.args[/:(\S+)/, 1]
      return name ? { type: :symbol, name: name } : nil
    when /^LOADI/
      # Same two literal shapes as LOADI's codegen.
      lit = insn.args[/\(([^)]+)\)/, 1] || insn.args[/^R\d+\s+(-?\d+)/, 1]
      return lit ? { type: :fixnum, value: lit } : nil
    else
      # Anything else writing `reg` means the receiver is not a literal.
      return nil
    end
  end
  # Never written: an argument or block-entry register, not a literal. No
  # "argument is always literal N" fact exists to fall back on.
  nil
end
