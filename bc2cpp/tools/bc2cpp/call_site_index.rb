# frozen_string_literal: true

# Shared index for analyses that need to visit every call to one method name.
# Build once per bc2cpp invocation rather than rescanning all instructions for
# every monomorphic name.
class CallSiteIndex
  SEND_OPS = %w[SEND0 SEND SENDB SSEND0 SSEND SSENDB].freeze
  # Kernel#to_enum / enum_for (mrblib): `to_enum(:meth, *args)` later runs `meth(*args)` on the receiver, so the
  # site is a caller of `meth` although no SEND spells it.
  ENUM_SENDS = %w[to_enum enum_for].freeze
  # Key of the sites whose method name is not a literal: any name could be their target. It is no
  # method name, so no registry entry collides with it. Read every list through .sites.
  UNKNOWN_TARGET = '(to_enum with a computed name)'
  # OP_SUPER (vm.c) is `goto L_SENDB_SYM` with mid = ci->mid, the ENCLOSING method's name, and the
  # same a/c operand layout as SENDB (args at R[a+1..], count c). It has no :name operand, so
  # `build` keys it by the name of the nearest enclosing `def` body. Without it the one `def set` a
  # `Class.new(A) { def set(x) = super("s") }` super call reaches (that def is in a block, so not
  # in the registry: `set` stays MONO) would look fed by its direct callers only.
  SUPER_OP = 'SUPER'
  NAME_RE = /:([\w+\-*\/<>=!?\[\]&|^~%@]+)/

  def self.build(ireps)
    by_name = Hash.new { |hash, name| hash[name] = [] }
    super_names = nil
    ireps.each_value do |irep|
      irep.each_with_op(*SEND_OPS, SUPER_OP) do |insn, idx|
        name = insn.op == SUPER_OP ? (super_names ||= enclosing_def_names(ireps))[irep.label] : insn.sym
        next unless name

        dest = insn.reg.to_i
        # A packed send (`f(*a)`, n=*, vm.c CALL_MAXARGS) has no count: nil, so no consumer reads it as 0 args.
        argc = insn.n_spec == '*' || (insn.nk_spec && insn.nk_spec != '0') ? nil : insn.argc.to_i
        by_name[name] << [irep, idx, dest, argc]
        add_enum_site(by_name, irep, idx, insn, dest, argc) if ENUM_SENDS.include?(name)
      end
    end
    by_name
  end

  # The call sites a consumer must treat as reaching +name+: its own plus every to_enum site whose target
  # name is computed. A computed-name site is kept as a caller of EVERY name (same arity matching as any
  # other caller), the conservative choice over refusing the whole analysis: it only ever adds callers.
  def self.sites(index, name)
    index.fetch(name, []) + index.fetch(UNKNOWN_TARGET, [])
  end

  # `to_enum(:meth, a, b)` is a call `meth(a, b)`. Register dest + 1 holds :meth, so the entry is anchored at
  # dest + 1 and counts one fewer argument: a consumer's register dest' + k is then argument k of meth. A
  # keyword (nk) or packed (n=*) site has no count, exactly like a direct send, which blocks the facts of
  # meth. A block is to_enum's size block, not an argument of meth. No arguments at all means `:each`.
  def self.add_enum_site(by_name, irep, idx, insn, dest, argc)
    forwarded = argc && (argc - 1)
    if argc == 0
      by_name['each'] << [irep, idx, dest + 1, 0]
      return
    end
    target = enum_target(irep, idx, insn, dest + 1)
    by_name[target || UNKNOWN_TARGET] << [irep, idx, dest + 1, forwarded]
  end

  # The literal method name of the site, or nil. Only a straight-line LOADSYM counts: a jump landing between
  # the symbol and the send (`cond ? :a : :b`) leaves several writers, of which a backward walk sees one.
  def self.enum_target(irep, idx, insn, reg)
    packed = insn.n_spec == '*'
    # Packed: `[:meth, ...] + *args` is LOADSYM R; ARRAY R n; ARYCAT/ARYPUSH R ...
    writer = irep.walk_writers(idx - 1, reg.to_s, follow_moves: true) do |w, i, _r|
      case w.op
      when 'LOADSYM' then ([w, i] if w.sym)
      when 'ARYCAT', 'ARYPUSH' then packed ? IrepScans::KEEP : nil
      when 'ARRAY' then packed && w.uint_operand.to_i.positive? ? IrepScans::KEEP : nil
      end
    end
    return nil unless writer.is_a?(Array)

    sym_insn = writer.first
    return nil if irep.instructions.any? { |j| (t = j.branch_target) && t > sym_insn.addr && t <= insn.addr }

    sym_insn.sym
  end

  # irep label -> name of its nearest enclosing `def` body (the irep itself when it is one), from the
  # def instructions themselves (TDEF, SDEF, METHOD+DEF) rather than the registry, which omits defs
  # inside blocks. Unresolvable (a block never under a `def`, e.g. `define_method(:n) { super }`): no
  # entry, and that name is a DynamicNames literal, which the joins already refuse.
  def self.enclosing_def_names(ireps)
    body_name = {}
    parent = {}
    ireps.each_value do |irep|
      (irep.reps || []).each { |child| parent[child] = irep.label }
      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'TDEF', 'SDEF'
          child = irep.reps[insn.block_index]
          body_name[child] = insn.sym if child && insn.sym
        when 'DEF'
          mi = irep.previous_real_index(idx - 1)
          meth = mi >= 0 ? irep.instructions[mi] : nil
          next unless meth && meth.op == 'METHOD' && insn.paren_reg == meth.reg

          child = irep.reps[meth.block_index]
          body_name[child] = insn.sym if child && insn.sym
        end
      end
    end
    ireps.each_key.each_with_object({}) do |label, out|
      up = label
      up = parent[up] until up.nil? || body_name.key?(up)
      out[label] = body_name[up] if up
    end
  end
end
