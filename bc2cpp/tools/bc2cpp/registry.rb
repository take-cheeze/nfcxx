# frozen_string_literal: true

# Step 6: the whole-program class/method registry.

# STRUCT_MEMBERS_ANALYSIS: `Const = Struct.new(:a, :b, ...)` (with or without
# a block, keyword_init or not) stores member i at array index i: mruby-struct
# struct.c writes mrb_ary_set(self, i, ...) for the i-th __members__ entry, and
# MRB_TT_STRUCT is RArray-backed (value.h), so RARRAY_PTR/LEN work directly.
#
# Returns `[owner, [member names in declared order]]` or nil when anything is
# not confidently recognized (anonymous Struct, receiver not a bare `Struct`
# GETCONST, LOADSYM scan count mismatch). A miss only means GETIDX keeps
# dynamic dispatch for that owner.
#
# Two argument shapes: n <= CALL_MAXARGS members in consecutive LOADSYM
# registers, or more (`n=*`) packed into one ARRAY first.
def detect_struct_new_members(irep, idx, insn, namespace)
  name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
  return nil unless name == 'new'

  d = insn.args[/^R(\d+)/, 1]
  return nil unless d

  struct_recv = false
  (idx - 1).downto(0) do |i|
    prev = irep.instructions[i]
    pd = prev.args[/^R(\d+)/, 1]
    next unless pd == d

    struct_recv = prev.op == 'GETCONST' && prev.args[/^R\d+\s+(\S+)/, 1] == 'Struct'
    break
  end
  return nil unless struct_recv

  # The Struct's name comes from a SETCONST right after the call on the same
  # register; an unnamed Struct.new is left unrecognized.
  next_insn = irep.instructions[idx + 1]
  struct_name = if next_insn && next_insn.op == 'SETCONST'
                  sc_name, sc_reg = next_insn.args.split(/\s+/, 2)
                  sc_name if sc_reg == "R#{d}"
                end
  return nil unless struct_name

  owner = namespace ? "#{namespace}::#{struct_name}" : struct_name

  scan_from = idx - 1
  if %w[SENDB SSENDB].include?(insn.op)
    return nil unless irep.instructions[scan_from]&.op == 'BLOCK'

    scan_from -= 1
  end

  # `keyword_init:` is Struct.new's only keyword; skip its (key, value) pair.
  nk = insn.args[/nk=(\d+)/, 1].to_i
  scan_from -= 2 * nk
  return nil if scan_from < 0 && nk.positive?

  pos = insn.args[/n=(\*|\d+)/, 1]
  return nil unless pos

  if pos == '*'
    array_insn = scan_from >= 0 ? irep.instructions[scan_from] : nil
    return nil unless array_insn&.op == 'ARRAY'

    n = array_insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
    return nil unless n

    scan_from -= 1
  else
    n = pos.to_i
    return nil if n.zero?
  end

  members = []
  i = scan_from
  while i >= 0 && members.size < n
    prev = irep.instructions[i]
    break unless prev.op == 'LOADSYM'

    members.unshift(prev.args[/:(\S+)/, 1])
    i -= 1
  end
  return nil unless members.size == n && members.all?

  [owner, members]
end

# ---------------------------------------------------------------------------
# Step 6: whole-program class/method registry, walking the tree from the
# root: CLASS/EXEC pairs define classes and recurse into their class-body
# irep; TDEF (anywhere) defines one method, owned by the innermost class
# being walked (or "Object" for a top-level TDEF).
# ---------------------------------------------------------------------------
def build_registry(ireps, root_label)
  registry = Hash.new { |h, k| h[k] = [] }
  # SUPER_SUPPORT: class name -> declared superclass name, :none (no explicit
  # superclass; OP_SUPER searches from one level above the current class either
  # way), or absent (unrecognized superclass expression, never guessed). Only
  # CLASS populates it; modules have no superclass.
  superclass_of = {}
  # ANCESTOR_MIXINS_SUPPORT: class name -> modules its own body `include`s, in
  # source order, plus the parallel `prepend` table. `super` soundness needs to
  # know that no included module sits between the caller and its superclass
  # (mruby's method search would hit the module's method first). Only the
  # self-implicit `include M` / `prepend M` form (SSEND R(self) :include n=1
  # after a GETCONST/GETMCNST) is recognized; anything else lands in
  # `unknown_mixins` so `super` in that owner declines. Prepended modules sit
  # above the class, so they never intervene and are not consulted by that check.
  included_modules = {}
  prepended_modules = {}
  unknown_mixins = Set.new
  # CONST_CONTAINER_SUPPORT: qualified constant name -> 'Array'/'Hash'/'Range'
  # when every SETCONST of that name writes a proven literal_container_class
  # value. Disagreeing sites poison the name to nil; poisoned entries are
  # removed before returning. A literal's shape is a one-shot syntactic fact,
  # so no fixed point is needed (unlike ClassLayout).
  container_constants = {}
  # STRUCT_MEMBERS_ANALYSIS result: qualified Struct owner -> member names in
  # storage-index order. See detect_struct_new_members.
  struct_member_lists = {}
  # CLOSED_WORLD: every CLASS opcode's superclass ref (nil when unresolved) and
  # whether its outer was implicit, plus every irep this walk visited.
  class_decls = Hash.new { |h, k| h[k] = [] }
  module_body_ivar_labels = Hash.new { |h, k| h[k] = [] }
  walked = Set.new

  walk = lambda do |label, namespace|
    walked << label
    irep = ireps.fetch(label)
    # Which register holds the class/module/singleton class just opened by
    # CLASS/MODULE/SCLASS, so its EXEC can be matched. pending_idx pins the EXEC to
    # the literal next instruction: mrbc always emits it there, and an empty body
    # (`class Timeout < StandardError; end`) emits no EXEC at all, so matching "the
    # next EXEC on this register" would attach an unrelated later body to the empty
    # class (this registered RGSS.asset_archive under RGSS::Timeout).
    pending_reg = nil
    pending_name = nil
    pending_idx = nil
    pending_ivar_owner = nil
    # `private`/`protected`/`public` tracking, scoped to this body. A bare call
    # (n=0) switches the mode for later defs; a call with Symbol arguments marks
    # already-defined methods without changing the mode. Getting visibility wrong
    # would let a register.cxx registration expose a private method.
    default_visibility = :public

    # Resolve a singleton receiver's name by walking back from `before_idx` to
    # `reg`'s last write. Only LOADSELF (the innermost namespace) and a GETCONST are
    # trusted; anything else is unrecognized (a safe miss). Shared by the SCLASS
    # body case and the unfused DEF case below.
    resolve_singleton_receiver = lambda do |reg, before_idx|
      recv = nil
      (before_idx - 1).downto(0) do |i|
        prev = irep.instructions[i]
        pd = prev.args[/^(R\d+)/, 1]
        next unless pd == reg

        case prev.op
        when 'LOADSELF'
          recv = namespace || 'Object'
        when 'GETCONST'
          const_name = prev.args[/^R\d+\s+(\S+)/, 1]
          recv = namespace ? "#{namespace}::#{const_name}" : const_name
        end
        break
      end
      recv
    end

    # Shared by TDEF and the unfused TCLASS+METHOD+DEF case: both need the builtin
    # always-private names (see the TDEF case).
    resolve_def_visibility = lambda do |method_name|
      %w[initialize initialize_copy
         respond_to_missing?].include?(method_name) ? :private : default_visibility
    end

    # mrbc -v prints OP_EXT1/EXT2/EXT3 as their own lines between instructions
    # codegen emits back to back (src/codedump.c; each widens the next
    # instruction's operands). The unfused DEF case always has one (its METHOD
    # index is > 0xff by construction). Returns the index of the first real opcode
    # before `from_idx`, or -1.
    skip_ext_back = lambda do |from_idx|
      i = from_idx
      i -= 1 while i >= 0 && %w[EXT1 EXT2 EXT3].include?(irep.instructions[i]&.op)
      i
    end

    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'CLASS', 'MODULE'
        # "CLASS R4 :Animal" / "MODULE R1 :Game" -- args "R4\t:Animal"
        reg, name = insn.args.split(/\s+/, 2)
        pending_reg = reg
        pending_idx = idx
        pending_ivar_owner = nil
        # Qualified name (Game::CharSet) so same-named nested classes stay distinct.
        pending_name = namespace ? "#{namespace}::#{name.sub(/^:/, '')}" : name.sub(/^:/, '')
        if insn.op == 'MODULE'
          pending_ivar_owner = "#{pending_name}.singleton"
        end
        # SUPER_SUPPORT: OP_CLASS is `R[a] = newclass(R[a], Syms[b], R[a+1])`
        # (mruby/ops.h, vm.c), and the superclass expression is evaluated right before
        # it, so resolve_superclass_ref walks back from this CLASS.
        if insn.op == 'CLASS'
          superclass_reg = (reg[/\d+/].to_i + 1).to_s
          resolved = resolve_superclass_ref(irep, idx, superclass_reg, namespace)
          superclass_of[pending_name] = resolved if resolved
          outer_nil = resolve_superclass_ref(irep, idx, reg[/\d+/], nil) == :none
          class_decls[pending_name] << { super: resolved, outer_nil: outer_nil }
        end
      when 'SCLASS'
        # "SCLASS R1": R[a] = R[a].singleton_class. A `class << self` / `class <<
        # SomeConst` body holds ordinary TDEFs, so it is walked like a CLASS/MODULE body
        # by the same EXEC-matching code below. Without this, defs inside it (e.g.
        # RGSS::Bitmap.extensions) were unregistered.
        # The receiver is resolved by resolve_singleton_receiver (LOADSELF or GETCONST
        # only; anything else is a safe miss).
        reg = insn.args[/^(R\d+)/, 1]
        recv = resolve_singleton_receiver.call(reg, idx)
        pending_reg = reg
        pending_idx = idx
        pending_ivar_owner = nil
        # "X.singleton" is a pseudo-owner, never a real constant path, so ONLY_OWNERS
        # can never select it. nil (unrecognized receiver) keeps EXEC from recursing.
        pending_name = recv ? "#{recv}.singleton" : nil
      when 'SETCONST'
        # CONST_CONTAINER_SUPPORT: "SETCONST NAME Rsrc" in a class/module body;
        # `namespace` is this body's lexical nesting. Only the literal (optionally
        # frozen) shape is recognized; anything else is a safe miss (nil).
        const_name = insn.args[/^(\S+)/, 1]
        src_reg = insn.args[/R(\d+)/, 1]
        qualified = namespace ? "#{namespace}::#{const_name}" : const_name
        klass = literal_container_class(irep, idx, src_reg)
        # Two disagreeing (or unresolvable) sites poison the name to nil; never
        # guess which one wins.
        if container_constants.key?(qualified)
          container_constants[qualified] = nil if container_constants[qualified] != klass
        else
          container_constants[qualified] = klass
        end
      when 'EXEC'
        reg, irep_ref = insn.args.split(/\s+/, 2)
        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        if reg == pending_reg && pending_name && idx == pending_idx + 1
          module_body_ivar_labels[pending_ivar_owner] << child_label if pending_ivar_owner
          walk.call(child_label, pending_name)
        end
        pending_reg = nil
        pending_name = nil
        pending_idx = nil
        pending_ivar_owner = nil
      when 'TDEF'
        # "TDEF R1 :speak I[1]"
        _reg, name, irep_ref = insn.args.split(/\s+/, 3)
        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        method_name = name.sub(/^:/, '')
        owner = namespace || 'Object' # a top-level `def` lands on Object.
        # #initialize, #initialize_copy and #respond_to_missing? are always private,
        # whatever mode is in effect: src/class.c's define_method path sets
        # MRB_METHOD_PRIVATE_FL for them unconditionally. default_visibility cannot
        # see that rule, and reporting them public would let register.cxx expose them.
        visibility = resolve_def_visibility.call(method_name)
        registry[method_name] << MethodDef.new(name: method_name, owner: owner, irep: child_label,
                                                visibility: visibility)
      when 'SDEF'
        # "SDEF R1 :clamp I[5]": `def self.foo` / `def SomeConst.foo`. codegen_sdef
        # (mruby-compiler codegen.c) fuses SCLASS+METHOD+DEF into SDEF whenever the
        # child irep index fits a byte, installing Irep[c] on R[a]'s singleton class.
        #
        # It must be registered (under the "Owner.singleton" pseudo-owner) or a
        # same-named instance method elsewhere looks MONO and call sites devirtualize
        # into the wrong body (Game.clamp vs RPG2k::Scene::MapViewer#clamp). Adding a
        # def can only turn an unsound MONO into POLY, never lose a sound one.
        #
        # I[c] is a real child irep, so it is recorded as `irep:` (docs/adr/0139);
        # with irep: nil the method could never become a compile target. That is safe
        # for every `d.irep` reader: natively_exposed? only compares against instance
        # owners from ivar_layout, never ".singleton" ones.
        #
        # The receiver is an arbitrary expression (codegen_sdef runs `codegen(s, recv,
        # VAL)`, and vm.c's OP_SDEF uses mrb_singleton_class(regs[a])), so it is
        # resolved with resolve_singleton_receiver rather than assuming `self`; that
        # scan already skips interposed EXT lines. An unrecognized receiver is not
        # registered rather than attributed to `namespace`.
        reg, sname, irep_ref = insn.args.split(/\s+/, 3)
        sdef_name = sname.sub(/^:/, '')
        sdef_idx = irep_ref[/I\[(\d+)\]/, 1].to_i
        sdef_child_label = irep.reps[sdef_idx]
        recv = resolve_singleton_receiver.call(reg, idx)
        if recv
          registry[sdef_name] << MethodDef.new(name: sdef_name, owner: "#{recv}.singleton",
                                                irep: sdef_child_label, visibility: :public)
        end
      when 'DEF'
        # "DEF R1 :toned? (R2)": codegen_def/codegen_sdef fuse into TDEF/SDEF only
        # when the child irep index fits a byte; past 255 children (RPG2k::Scene::Map)
        # they emit the unfused sequence instead:
        #   TCLASS  R1            LOADSELF R1 / SCLASS R1   (for `def self.x`)
        #   EXT2
        #   METHOD  R2  I[380]
        #   EXT2
        #   DEF     R1  :toned?  (R2)
        # skip_ext_back steps over the interposed EXT lines.
        reg, name, recv_arg = insn.args.split(/\s+/, 3)
        method_idx = skip_ext_back.call(idx - 1)
        method_insn = method_idx >= 0 ? irep.instructions[method_idx] : nil
        next unless method_insn && method_insn.op == 'METHOD'

        method_reg, irep_ref = method_insn.args.split(/\s+/, 2)
        # Registers must line up as codegen emits them (opener at R<n>, METHOD at
        # R<n+1>, DEF at R<n> referencing (R<n+1>)); adjacency alone is not trusted.
        next unless recv_arg == "(#{method_reg})"

        opener_idx = skip_ext_back.call(method_idx - 1)
        opener_insn = opener_idx >= 0 ? irep.instructions[opener_idx] : nil
        next unless opener_insn && %w[TCLASS SCLASS].include?(opener_insn.op)

        opener_reg = opener_insn.args[/^(R\d+)/, 1]
        next unless opener_reg == reg

        idx2 = irep_ref[/I\[(\d+)\]/, 1].to_i
        child_label = irep.reps[idx2]
        def_name = name.sub(/^:/, '')

        if opener_insn.op == 'TCLASS'
          # Unfused `def foo`: registered exactly like a TDEF, with a real irep.
          owner = namespace || 'Object' # a top-level `def` lands on Object.
          visibility = resolve_def_visibility.call(def_name)
          registry[def_name] << MethodDef.new(name: def_name, owner: owner, irep: child_label,
                                               visibility: visibility)
        else
          # Unfused `def self.foo`: same "X.singleton" pseudo-owner and real irep as
          # SDEF, receiver resolved by resolve_singleton_receiver (unrecognized: not
          # registered). Visibility is always :public: singleton-method privacy is not
          # modelled for either shape.
          recv = resolve_singleton_receiver.call(opener_reg, opener_idx)
          if recv
            owner = "#{recv}.singleton"
            registry[def_name] << MethodDef.new(name: def_name, owner: owner, irep: child_label,
                                                 visibility: :public)
          end
        end
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND'
        # Same charset as compile_send's name extraction; keep the two in sync.
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        if name == 'new'
          # STRUCT_MEMBERS_ANALYSIS for the block-less `Const = Struct.new(...)` shape.
          # Additive only: returns nil for anything but a SETCONST-named Struct.new.
          found = detect_struct_new_members(irep, idx, insn, namespace)
          struct_member_lists[found[0]] = found[1] if found
        end
        if %w[include prepend].include?(name)
          # ANCESTOR_MIXINS_SUPPORT: a self-implicit `include M`/`prepend M` in this
          # body (walk only recurses into CLASS/MODULE/SCLASS bodies, so `namespace` is
          # the owner). mrbc emits `GETCONST R(a+1) M` right before `SSEND R(a) :include
          # n=1`. An explicit receiver, several arguments or a non-constant module flags
          # the owner in `unknown_mixins` so `super` there declines.
          mixin_owner = namespace || 'Object'
          self_reg = insn.args[/^R(\d+)/, 1]
          mixin_n = insn.args[/n=(\d+)/, 1]&.to_i
          recognized = %w[SSEND SSEND0].include?(insn.op) && mixin_n == 1 && self_reg
          mod = recognized ? resolve_superclass_ref(irep, idx, (self_reg.to_i + 1).to_s, namespace) : nil
          if recognized && mod.is_a?(String)
            table = name == 'include' ? included_modules : prepended_modules
            (table[mixin_owner] ||= []) << mod
          else
            unknown_mixins << mixin_owner
          end
          next
        end
        next unless %w[private protected public attr_reader attr_writer attr_accessor
                       module_function].include?(name)

        n = insn.args[/n=(\d+)/, 1].to_i
        # 15+ arguments are packed into one ARRAY (CALL_MAXARGS) and sent as n=*.
        packed = insn.args.include?('n=*')
        if packed
          arr = idx.positive? && irep.instructions[idx - 1]
          n = arr && arr.op == 'ARRAY' ? arr.args[/R\d+\s+(\d+)/, 1].to_i : -1
          raise "bc2cpp: #{name} with a splat argument at #{irep.label}:#{insn.addr} names methods statically unknown" if n <= 0
        end
        # `private :a, :b` / `attr_reader :a, :b`: the Symbol arguments are LOADSYM'd
        # into consecutive registers right before the send; walk back to collect them.
        collect_loadsym_names = lambda do
          names = []
          (idx - (packed ? 2 : 1)).downto(0) do |i|
            break if names.size >= n

            prev = irep.instructions[i]
            break unless prev.op == 'LOADSYM'

            names.unshift(prev.args[/:(\S+)/, 1])
          end
          names
        end

        if %w[private protected public].include?(name)
          if n.zero?
            default_visibility = name.to_sym
          else
            # `private :a, :b, ...` -- retroactively marks already-defined
            # methods, without changing the mode for whatever comes after.
            collect_loadsym_names.call.each do |mname|
              def_ = registry[mname]&.find { |d| d.owner == namespace }
              def_.visibility = name.to_sym if def_
            end
          end
        elsif name == 'module_function'
          # `module_function :a, :b` installs a public copy of each instance method on
          # the module's singleton class. In mruby (src/class.c
          # mrb_mod_module_function), unlike CRuby, the instance method stays as it was
          # (the make-private call is commented out), so only the singleton copy needs a
          # registry entry. It is added as "Owner.singleton" with irep: nil: the registry
          # cannot express "two owners, one irep", and irep: nil can only prevent a
          # direct call, never enable a wrong one. Only the retroactive (n >= 1) form is
          # handled; the bare mode-switch form does not occur in this closed world.
          collect_loadsym_names.call.each do |mname|
            registry[mname] << MethodDef.new(name: mname, owner: "#{namespace || 'Object'}.singleton",
                                              irep: nil, visibility: :public)
          end
        else
          # attr_reader/attr_writer/attr_accessor are native, so their accessors get no
          # TDEF. Each name is registered as a synthetic MethodDef (irep: nil) so a
          # same-named bytecode def elsewhere is not MONO: Game::Battle#critical?'s
          # `b.crit_chance` (b an Actor or an Enemy) otherwise devirtualized into
          # Game::Actor#crit_chance and raised NoMethodError for enemies. This can only
          # turn an unsound MONO into POLY.
          getter_flag = %w[attr_reader attr_accessor].include?(name)
          setter_flag = %w[attr_writer attr_accessor].include?(name)
          collect_loadsym_names.call.each do |mname|
            owner = namespace || 'Object'
            # kind: :ivar_accessor (see MethodDef): src/class.c's attr_reader/attr_writer
            # are exactly mrb_iv_get/mrb_iv_set on the bare `@name`; consumed by
            # IVAR_ACCESSOR_DEVIRT.
            if getter_flag
              registry[mname] << MethodDef.new(name: mname, owner: owner, irep: nil, visibility: :public,
                                                kind: :ivar_accessor)
            end
            if setter_flag
              registry["#{mname}="] << MethodDef.new(name: "#{mname}=", owner: owner, irep: nil,
                                                       visibility: :public, kind: :ivar_accessor)
            end
          end
        end
      when 'SENDB'
        # STRUCT_MEMBERS_ANALYSIS for the block-taking form; additive only.
        found = detect_struct_new_members(irep, idx, insn, namespace)
        struct_member_lists[found[0]] = found[1] if found

        # `Const = Struct.new(:a, ...) do ... end`: no CLASS opcode opens the block,
        # and the member accessors are native (struct.c), so both the block's defs and
        # the member names are invisible to the plain walk. Without registering them,
        # Game::Battle::Combatant#state? and #actor looked MONO and devirtualized into
        # Game::Actor/RPG2k::Scene::EquipMenu bodies that read ivars a Struct does not
        # have (Struct members are positional, not iv_tbl).
        name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
        next unless name == 'new'

        d = insn.args[/^R(\d+)/, 1]
        # Only a bare `Struct` GETCONST receiver is trusted; anything else is a safe
        # miss.
        struct_recv = false
        (idx - 1).downto(0) do |i|
          prev = irep.instructions[i]
          pd = prev.args[/^R(\d+)/, 1]
          next unless pd == d

          struct_recv = prev.op == 'GETCONST' && prev.args[/^R\d+\s+(\S+)/, 1] == 'Struct'
          break
        end
        next unless struct_recv

        # The block operand is the BLOCK right before the SENDB (codegen emits it
        # there).
        block_insn = irep.instructions[idx - 1]
        next unless block_insn && block_insn.op == 'BLOCK'

        block_idx = block_insn.args[/I\[(\d+)\]/, 1]
        next unless block_idx

        block_label = irep.reps[block_idx.to_i]
        next unless block_label

        # The owner name comes from a SETCONST right after the SENDB. An unnamed
        # Struct still gets a placeholder owner: soundness only needs a distinct
        # owner so `defs.size == 1` sees more than one definition.
        next_insn = irep.instructions[idx + 1]
        struct_name = if next_insn && next_insn.op == 'SETCONST'
                         sc_name, sc_reg = next_insn.args.split(/\s+/, 2)
                         sc_name if sc_reg == "R#{d}"
                       end
        owner = struct_name ? (namespace ? "#{namespace}::#{struct_name}" : struct_name) : "<struct:#{label}:#{idx}>"

        # Member names are LOADSYM'd right before the ARRAY that packs the splat.
        # Struct installs a reader and a writer for each (struct.c), like
        # attr_accessor.
        array_insn = irep.instructions[idx - 2]
        if array_insn && array_insn.op == 'ARRAY'
          n = array_insn.args[/^R\d+\s+(\d+)/, 1].to_i
          members = []
          (idx - 3).downto(0) do |i|
            break if members.size >= n

            prev = irep.instructions[i]
            break unless prev.op == 'LOADSYM'

            members.unshift(prev.args[/:(\S+)/, 1])
          end
          members.each do |m|
            registry[m] << MethodDef.new(name: m, owner: owner, irep: nil, visibility: :public)
            registry["#{m}="] << MethodDef.new(name: "#{m}=", owner: owner, irep: nil, visibility: :public)
          end
        end

        # Walk the block body like a class body, so its defs get real ireps.
        walk.call(block_label, owner)
      end
    end
  end

  walk.call(root_label, nil)
  [registry, superclass_of, container_constants.compact, included_modules, prepended_modules, unknown_mixins,
   struct_member_lists, class_decls, walked, module_body_ivar_labels]
end

# SUPER_SUPPORT: resolve `class X < SUPER_EXPR` to a class name by walking back
# from the CLASS instruction. Only a bare GETCONST (resolved against the real
# lexical `namespace`, one level, like resolve_singleton_receiver), GETMCNST,
# or a MOVE of one is recognized; anything else returns nil (absent from
# superclass_of, never a wrong guess).
def resolve_superclass_ref(irep, before_idx, reg, namespace)
  path = []
  (before_idx - 1).downto(0) do |i|
    insn = irep.instructions[i]
    d = insn.args[/^R(\d+)/, 1]
    next unless d == reg

    case insn.op
    when 'MOVE'
      reg = insn.args.scan(/R(\d+)/).flatten[1]
    when 'LOADNIL'
      return :none # no explicit superclass written -- real Ruby default is Object.
    when 'GETMCNST'
      path.unshift(insn.args[/::(\w+)/, 1])
    when 'GETCONST'
      const_name = insn.args[/^R\d+\s+(\S+)/, 1]
      return path.empty? ? (namespace ? "#{namespace}::#{const_name}" : const_name) : path.unshift(const_name).join('::')
    else
      return nil
    end
  end
  nil
end
