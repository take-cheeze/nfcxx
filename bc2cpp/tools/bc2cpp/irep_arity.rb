# frozen_string_literal: true

# Argument shapes and block/lambda/def fallback safety of an irep.

def pure_mandatory_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[1..].all?(&:zero?)
end

# ENTER's mandatory count (fields[0]), used by compile_send's MONO guard to
# refuse a direct call whose argument count differs from the target's arity.
def mandatory_arity(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return 0 unless enter

  enter.args.split(':').first.to_i
end

# KEYWORD_HASH_POSITIONAL_OPTIONAL_ARG_SUPPORT: can this def receive `nk`
# keyword pairs packed into one trailing positional Hash, with `total`
# positionals? (see compile_keyword_hash_positional_send). Sound when ENTER has
# kd == 0 (no KEY, no KDICT): vm.c OP_ENTER's `if (!kd) { ci->n++; argc++; }`
# then treats the Hash as the next positional, so optional positionals are
# fine (`def foo(a, b = 1)` gets the Hash in b). `total.between?(mand, mand +
# opt)` accepts only what the VM accepts without raising. rest/post/block/
# noblock stay excluded (they move where the Hash lands). ENTER's fields are
# REQ:OPT:REST:POST:KEY:KDICT:BLOCK:NOBLOCK (src/codedump.c).
def keyword_hash_positional_callee?(irep, total)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  mand, opt, rest, post, kw, kdict, block, noblock =
    enter.args.split(':').map { |f| f[/\d+/].to_i }
  kw.zero? && kdict.zero? && rest.zero? && post.zero? && block.zero? && noblock.zero? &&
    total.between?(mand, mand + opt)
end

# KEYWORD_DIRECT_CONSTRUCT_SUPPORT: ENTER with mandatory positionals, optional
# positionals, and KEYWORD parameters (kw > 0); rest/post/kwrest/block/noblock
# must be zero. pure_mandatory_arity? requires kw == 0, so a keyword
# #initialize never reaches the non-keyword construct path.
# e.g. `Game::MoveRoute#initialize(commands, repeat: true, skippable: false)`
# is `ENTER 1:0:0:0:2:0:0:0`.
# KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT: optional positionals are
# allowed because compile_keyword_direct_construct pads the `_impl` call with
# mrb_nil_value() up to `mand + opt` plus `bc2cpp_given_opt` (the same splice
# as compile_keyword_call); without that padding, g++ fails with "too few
# arguments". With opt == 0 the output is unchanged.
def mandatory_optional_and_keyword_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, _opt, rest, post, kw, kwrest, block, noblock = fields
  kw.to_i.positive? && rest.to_i.zero? && post.to_i.zero? &&
    kwrest.to_i.zero? && block.to_i.zero? && noblock.to_i.zero?
end

# BLOCK_CFUNC_FALLBACK_SUPPORT: can this block's irep be compiled as a
# top-level C++ function wrapped in a cfunc RProc
# (mrb_proc_new_cfunc_with_env)?
#
# `self` is fine: mrb_proc_get_self (src/proc.c) returns nil for a cfunc proc,
# so the enclosing method's self is captured in env slot 0 and read back with
# mrb_proc_cfunc_env_get(M, 0), ignoring the self mrb_yield passes. See
# emit_proc_fallback_fn/emit_block_fallback_glue.
#
# UPVAR_CAPTURE_SUPPORT: GETUPVAR/SETUPVAR capture a POINTER to the enclosing
# function's register local (mrb_cptr_value(M, &rN)). uvenv(mrb, up) walks `up`
# proc->upper hops (vm.c), so each captured level needs a matching frame (see
# collect_block_upvars). E.g. `GETUPVAR R3 4 0` in `list.each { |x| total +=
# x }` is the method's R4 at depth 0.
# Pointer capture is sound only if the callee runs the block synchronously and
# never stores it (LCF.lazy stores its block). That gate is
# BLOCK_FALLBACK_UPVAR_SAFE_METHODS in recognize_block_fallback_regions, not
# here.
#
# EXCEPTION_BREAK_SUPPORT: `break` becomes `throw bc2cpp_block_break`, caught
# at the SENDB call site (emit_block_fallback_glue); OP_BREAK unwinds to the
# yielding call with the break value as its result. mruby is built with
# MRB_USE_CXX_EXCEPTION (CMakeLists.txt), so MRB_TRY/MRB_CATCH are real C++
# try/catch and the throw unwinds through VM frames correctly.
# EXCEPTION_RETURN_SUPPORT: RETURN_BLK throws `bc2cpp_method_return`, caught
# around the whole enclosing method (compile_method's needs_return_catch). The
# per-call-site catch is for bc2cpp_block_break only, and C++ catch matching is
# exact, so the return passes through.
# NESTED_BLOCK_FALLBACK_SUPPORT: BLOCK/SENDB/SSENDB inside the block are
# handled by emit_proc_fallback_fn running the same recognize -> suppress ->
# glue pass recursively; an unresolved nested region leaves the raw opcodes,
# which still produce `#error`. A nested block's depth-0 upvar is the outer
# block's C++ local, which exists because the recursive pass runs inside the
# outer body's compile. @block_fallback_upvars/@block_fallback_active need no
# stack: each nested pass finishes and clears them before the outer level sets
# its own.
# BLOCK_FALLBACK_RESCUE_SUPPORT: RESCUE/RAISEIF/EXCEPT in the block are handled
# by running recognize_rescue_regions/emit_rescue_try_body/emit_rescue_glue on
# the block irep too. RESCUE/RAISEIF are always-correct translations; EXCEPT
# needs a recognized region, so unrecognized shapes still produce `#error`.
BLOCK_FALLBACK_UNSAFE_OPS = [].freeze

# UPVAR_CAPTURE_SUPPORT: sorted, de-duplicated outer registers the block's
# GETUPVAR/SETUPVAR reference. nil means "unsafe to capture" (distinct from []
# "nothing to capture").
def collect_block_upvars(block_irep)
  upvars = []
  block_irep.instructions.each do |insn|
    next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

    _reg, upvar_idx, depth = insn.args.split(/\s+/)
    return nil unless depth == '0'

    upvars << upvar_idx.to_i
  end
  upvars.uniq.sort
end

# DEEP_UPVAR_CAPTURE_SUPPORT: a captured pointer is named by (level, index),
# not index alone: the same index at two levels names two variables, e.g. in
# `2.times do |j| 2.times do |i| ... quarters[j][i] ... end end`:
#   GETUPVAR R5 1 1   ; level 1, index 1 -- the METHOD's R1, `quarters`
#   GETUPVAR R6 1 0   ; level 0, index 1 -- the OUTER BLOCK's R1, `j`
# Level 0 keeps the un-suffixed spelling so existing output is unchanged.
def upvar_var_name(level, idx)
  level.zero? ? "bc2cpp_upvar_#{idx}" : "bc2cpp_upvar_u#{level}_#{idx}"
end

# UPVAR_CAPTURE_SUPPORT: the call-site half of the pointer-capture argument:
# the callee must run the block synchronously and never store it. A hand-vetted
# allowlist by NAME; every entry's body was read (mruby core, or this
# program's own methods such as each_event_position, page_field, section,
# cached_bitmap, auto_battle_best_target). Never add storage-like methods
# (lazy, define_method, callback registration) without the same check.
# A callee's own rescue/ensure (loop, page_field, File.open) is fine: under
# MRB_USE_CXX_EXCEPTION, MRB_CATCH (mruby/throw.h) catches only mrb_jmpbuf*,
# so a bc2cpp_block_break thrown through the yield passes through.
# Name-gated entries that depend on the current build, re-verify before
# changing it:
#   - `new`: assumed to be Array.new (mrb_ary_init yields synchronously). No
#     bytecode #initialize or native constructor here takes a block; adding
#     one breaks this assumption.
#   - `flat_map`, `zip`, `with_index`: Enumerator::Lazy's versions STORE the
#     block (mruby-enum-lazy). Safe only because mruby-enum-lazy is not in
#     build_config.rb and nothing here redefines these names. Re-verify
#     before adding that gem.
#   - `step`: this program's domain `def step` methods take no block and no
#     `.step {` call site exists, so only Numeric#step is reachable.
BLOCK_FALLBACK_UPVAR_SAFE_METHODS = %w[
  each each_with_index each_index each_key each_event_position
  times map select reject reject! delete_if
  find find_index any? all? none? count index sort_by
  _rgss_native_sort _rgss_native_sort! loop each_char
  page_field section open new reduce inject each_with_object downto
  auto_battle_best_target cached_bitmap flat_map gsub gsub! scan zip each_value
  sub sub! with_index step
].freeze

# The irep-only half of the block-fallback gate (arity plus the unsafe-op
# scan). The upvar-depth check lives in recognize_block_fallback_regions
# (`available_upvars`), which knows what the enclosing level can supply.
def block_fallback_safe?(block_irep)
  return false unless pure_mandatory_arity?(block_irep)

  block_irep.instructions.none? { |insn| BLOCK_FALLBACK_UNSAFE_OPS.include?(insn.op) }
end

# LAMBDA_FALLBACK_SUPPORT: the LAMBDA counterpart of block_fallback_safe?,
# sharing emit_proc_fallback_fn. A LAMBDA proc is always MRB_PROC_STRICT
# (opcode.h `OP_L_LAMBDA (OP_L_STRICT|OP_L_CAPTURE)`, codegen_lambda), and vm.c
# OP_RETURN_BLK/OP_BREAK both start with `if (MRB_PROC_STRICT_P(ci->proc)) goto
# NORMAL_RETURN;`. The child irep uses the same RETURN_BLK/BREAK opcodes as a
# block (lambda_body with blk=1), so only the constructing opcode tells them
# apart; this recognizer fires only for LAMBDA, so RETURN_BLK/BREAK are allowed
# here and compile to a plain return.
# Nested LAMBDA/BLOCK/SENDB/SSENDB and RESCUE/RAISEIF/EXCEPT are still
# rejected.
# CONFINED_LAMBDA_UPVAR_SUPPORT: upvars are captured as raw pointers into the
# enclosing C++ frame, so the proc must not outlive it. A lambda has no call
# site to vet, so recognize_lambda_fallback_regions requires
# lambda_proc_frame_confined? over the enclosing irep instead. A lambda with no
# upvars needs no such proof.
LAMBDA_FALLBACK_UNSAFE_OPS = %w[
  LAMBDA BLOCK SENDB SSENDB
  RESCUE RAISEIF EXCEPT
].freeze

def lambda_fallback_safe?(lambda_irep)
  return false unless pure_mandatory_arity?(lambda_irep)

  lambda_irep.instructions.none? { |insn| LAMBDA_FALLBACK_UNSAFE_OPS.include?(insn.op) }
end

# RUNTIME_DEF_FALLBACK_SUPPORT (SDEF_FALLBACK / SCLASS_FALLBACK+EXEC_FALLBACK):
# kinds emit_proc_fallback_fn compiles as a METHOD or CLASS body, not a block:
#   * `self` is the receiver mruby passes the cfunc, not env slot 0 (a block
#     ignores the passed self; a method or class body must use it);
#   * `@block_fallback_active` is false, so a BREAK keeps its `#error` (mrbc
#     rejects `break` at def/class top level anyway).
RUNTIME_DEF_FALLBACK_KINDS = %w[sdef_fallback tdef_fallback exec_fallback].freeze

# RUNTIME_DEF_FALLBACK_SUPPORT: the single predicate both consequences above
# key off.
def runtime_def_fallback_kind?(kind)
  RUNTIME_DEF_FALLBACK_KINDS.include?(kind)
end

# RUNTIME_DEF_FALLBACK_SUPPORT: can this `def` body be installed on a runtime
# class as a cfunc method?
# pure_mandatory_arity? is the load-bearing part: the entry wrapper binds
# parameters with `mrb_get_args(M, "oo...")`, which raises unless exactly
# `mand` arguments arrive. That matches a mandatory-only def and is wrong for
# any optional/rest/keyword/block parameter.
# Everything else already fails closed: the body is compiled with no captured
# upvars (GETUPVAR/SETUPVAR -> `#error`), no block parameter (BLKPUSH ->
# `#error`), and emit_proc_fallback_fn returns nil for any `#error`, which
# callers treat as "keep the original marker".
def runtime_def_body_safe?(def_irep)
  pure_mandatory_arity?(def_irep)
end

# CALLSITE_OPTIONAL_ARG_SUPPORT: ENTER's optional count (field 1), 0 when
# absent. compile_send uses it to pad a direct call with mrb_nil_value() and
# pass `bc2cpp_given_opt`, mirroring the entry wrapper's `mrb_get_argc(M) -
# mand`.
def optional_arity(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return 0 unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[1] || 0
end

# CALLSITE_OPTIONAL_ARG_SUPPORT: pure_mandatory_arity? that also accepts plain
# optional positionals (`def foo(a, b = 1)`); every other non-mandatory field
# must be zero. Callers still check compiles_clean? separately.
def pure_mandatory_or_optional_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return true unless enter # no ENTER at all: a 0-arg method, trivially fine.

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  fields[2..].all?(&:zero?)
end

# OPTIONAL_ARG_SUPPORT: models ENTER's optional field only. Returns
# [optional_count, jump_source_addrs, jump_target_addrs] for the recognized
# shape, else [0, nil, nil] (compile_method then emits `#error`).
# `def foo(a, b = 1, c = 2)` is `ENTER 1:2:0:0:0:0:0:0` followed by exactly
# optional + 1 JMPs; entry k (arguments supplied) jumps to the code computing
# default k+1, or to the body when all were supplied. This is OP_ENTER's
# PC skip (vm.c), reproduced as a switch/goto (emit_optional_dispatch), so any
# default expression the compiler can translate works.
# JMPNOT/JMPIF/JMPNIL print "R<reg>\t<target>", optionally followed by
# "; R<reg>:<name>" when the register is a named local. Anchor after the
# register: an end-anchored `/(\d+)\s*$/` returns nil there, and `nil.to_i` is
# a silent `goto L0`.
def jmp_target_after_reg(args)
  args[/^R\d+\s+(\d+)/, 1].to_i
end

def optional_arg_table(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return [0, nil, nil] unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # OPTIONAL_KEYWORD_COMBINED_SUPPORT: `kw` may be non-zero (`def f(a, b = 1, k:
  # nil)`): the default-value code falls through into the KEY_P/KARG/KEYEND
  # sequence keyword_arg_table recognizes independently.
  return [0, nil, nil] unless opt.positive? && rest.zero? && mand2.zero? && kwrest.zero? && block.zero?

  enter_idx = irep.instructions.index { |i| i.op == 'ENTER' }
  jmps = irep.instructions[enter_idx + 1, opt + 1]
  return [opt, nil, nil] unless jmps && jmps.size == opt + 1 && jmps.all? { |i| i.op == 'JMP' }

  [opt, jmps.map(&:addr), jmps.map { |i| i.args.strip[/\d+/].to_i }]
end

# KEYWORD_ARG_SUPPORT: parameter name for a keyword. compile_method (signature,
# mrb_kwargs extraction) and compile_insn's KEY_P/KARG cases (which only see
# the instruction's `:sym`) agree only because both use this function.
def kwarg_param_name(sym)
  "bc2cpp_kwarg_#{sanitize_c_ident(sym)}"
end

def kw_given_param_name(sym)
  "bc2cpp_kw_given_#{sanitize_c_ident(sym)}"
end

# KEYWORD_ARG_SUPPORT: plain keyword arguments with kwrest == 0 (a `**rest`
# register is filled by OP_ENTER itself, a different shape). KEY_P/KARG/KEYEND
# translate in place, so no region is needed; this only lists the keywords in
# bytecode order and whether each is required (a lone `KARG R4 :c` with no
# KEY_P) or optional (KEY_P/JMPIF guard). Returns [{name:, required:}], or nil
# for unmodeled fields or a count mismatch with ENTER.
def keyword_arg_table(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return nil unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # OPTIONAL_KEYWORD_COMBINED_SUPPORT: `opt` may be non-zero (see
  # optional_arg_table); this scan already covers the whole irep.
  return nil unless kw.positive? && rest.zero? && mand2.zero? && kwrest.zero? && block.zero?

  order = []
  required = {}
  irep.instructions.each do |insn|
    next unless insn.op == 'KEY_P' || insn.op == 'KARG'

    sym = insn.args[/:(\S+)/, 1]
    next unless sym

    unless required.key?(sym)
      order << sym
      required[sym] = true
    end
    required[sym] = false if insn.op == 'KEY_P'
  end
  return nil unless order.size == kw

  order.map { |sym| { name: sym, required: required[sym] } }
end

# REST_ARG_SUPPORT: `def foo(a, *rest)` (ENTER 1:0:1:0:0:0:0:0) with no other
# non-mandatory field. OP_ENTER (vm.c) fills the rest register with an Array
# before the body runs, and it sits right after the mandatory registers, so
# compile_method treats it as one more contiguous `total_args` slot.
def rest_only_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # REST_BLOCK_COMBINED_SUPPORT: `block` may be non-zero (`def m(name, *args,
  # &block)`, ENTER 1:0:1:0:0:0:1:0): the block arrives at register
  # mand+rest+1. Both are pure ENTER-field facts, so no bytecode recognition is
  # involved.
  rest.positive? && opt.zero? && mand2.zero? && kw.zero? && kwrest.zero?
end

# EXPLICIT_BLOCK_PARAM_SUPPORT: mandatory arguments plus `&blk` (ENTER
# 0:0:0:0:0:0:1:0, then `MOVE R2 R1 ; R2:blk`). The block arrives at register
# mand+1 through the ordinary entry convention, not BLKPUSH/BLKCALL.
def block_param_arity?(irep)
  enter = irep.instructions.find { |i| i.op == 'ENTER' }
  return false unless enter

  fields = enter.args.split(':').map { |f| f[/\d+/].to_i }
  _mand, opt, rest, mand2, kw, kwrest, block = fields
  # REST_BLOCK_COMBINED_SUPPORT: `rest` may be non-zero (see rest_only_arity?).
  block.positive? && opt.zero? && mand2.zero? && kw.zero? && kwrest.zero?
end
