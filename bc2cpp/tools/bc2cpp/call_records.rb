# frozen_string_literal: true

require_relative 'class_scope'
require_relative 'bytecode_ir'
require_relative 'send_names'

# CALL_RECORDS: the registry, alias and define_method scans, and the escape world's naming-send scan, take the literal names of
# `private :a`, `attr_reader :a, :b`, `alias_method :new, :old`, `define_method(:name) { }` from the emitter's `call` record of
# the send (ClassScope.call_at: the call as written) whenever the irep carries annotations, and from the register dataflow
# otherwise (trees from mrbc or a cache). The two are the same fact derived twice, so BC2CPP_CALL_CROSSCHECK=1 derives both at
# every site that has both and records what they say:
#
# The registry walk's own def decisions are checked the same way (agree_def): the emitter's DEF record names the owner and the
# visibility mode of every plain `def`.
#
# - agreement: nothing;
# - refinement: the dataflow gave up (a call past 14 arguments, a name it cannot follow) where the record names the call;
# - disagreement: both answered and differ, or the dataflow silently dropped a name the record has (`attr_reader "x"`). Each is
#   a bug in one of the two readers; they are listed at exit and fail the process (never papered over by preferring one).
#
# BC2CPP_CLASS_SCOPE=0 ignores annotations (ClassScope.enabled?), so a run with it is the pure dataflow.
module CallRecords
  Row = Struct.new(:kind, :where, :annotated, :derived, keyword_init: true)

  @disagreements = []
  @refinements = Hash.new(0)
  @checked = Hash.new(0)
  @hooked = false

  class << self
    attr_reader :disagreements, :refinements, :checked
  end

  module_function

  def crosscheck? = ENV['BC2CPP_CALL_CROSSCHECK'] == '1'

  # The `call` record of +insn+ in +irep+; nil when there is none (no annotations, or a send it does not describe).
  def at(irep, insn) = irep.class_scope && ClassScope.call_at(irep, insn)

  # Every argument is a literal Symbol or String (both name a method to attr_*, private, ...): those names, else nil.
  def literal_names(call)
    args = call[:args]
    args.map { |a| a[:value] } if args.all? { |a| %i[sym str].include?(a[:kind]) }
  end

  # Every argument is a literal Symbol: those names, else nil (the forms whose dataflow reading is a LOADSYM).
  def symbols(call)
    args = call[:args]
    args.map { |a| a[:value] } if args.all? { |a| a[:kind] == :sym }
  end

  # The arguments as names: a literal Symbol's, nil for anything else (a String, a splat, a computed value). One entry per
  # written argument, from +drop+ on.
  def names(call, drop = 0) = call[:args].drop(drop).map { |a| a[:kind] == :sym ? a[:value] : nil }

  # How many positional arguments were written; nil when a splat or keywords make the count a run-time value.
  def positional_count(call)
    args = call[:args]
    args.size unless args.any? { |a| %i[splat keywords].include?(a[:kind]) }
  end

  # A String argument: `attr_reader "x"` names x, but no LOADSYM spells it, so the dataflow cannot read it.
  def string_names?(call) = call[:args].any? { |a| a[:kind] == :str }

  # Cross-check one answer: +annotated+ from the record, +derived+ lazily from the dataflow (a block, run only when checking).
  # Returns +annotated+ either way, so the consumer's answer never depends on the mode.
  def agree(kind, irep, insn, annotated)
    return annotated unless crosscheck?

    hook!
    derived = yield
    @checked[kind] += 1
    if derived.nil? then @refinements[kind] += 1 unless annotated.nil?
    elsif derived != annotated then flag(kind, irep, insn, annotated, derived)
    end
    annotated
  end

  # The emitter's DEF record (owner and visibility of a plain `def`) against what the registry walk decided at the def. The walk's
  # answer is the one consumers use; the record is only checked. The walk marks `private def x` (the def handed to a visibility send
  # right after it) there, and `private :a` later, so the record's visibility is compared with the send's name in the first case and
  # a record without one ("not evident": inside a block or a method) says nothing.
  def agree_def(irep, idx, insn, owner, visibility)
    return unless crosscheck?

    op = ClassScope.op_at(irep, insn)
    return unless op && %i[class module top].include?(op[:owner_kind])

    agree(:def_owner, irep, insn, op[:owner_path]) { owner }
    recorded = op[:visibility]
    return unless recorded

    recorded = :private if recorded == :module_function || ALWAYS_PRIVATE.include?(insn.sym)
    following = BytecodeIR.for(irep).source_at(idx + 1)
    if following && %i[SSEND].include?(following.op) && SendNames::VISIBILITY_SENDS.include?(following.sym) && insn.reg == following.reg + 1 &&
       following.argc == 1
      visibility = following.sym.to_sym unless following.sym == 'module_function'
    end
    agree(:def_visibility, irep, insn, recorded) { visibility }
  end

  # mruby's own private-by-name rule (src/class.c), which a def's mode does not show.
  ALWAYS_PRIVATE = %w[initialize initialize_copy respond_to_missing?].freeze

  # A disagreement that needs no dataflow answer (the dataflow cannot say it at all).
  def flag(kind, irep, insn, annotated, derived)
    hook!
    op = ClassScope.op_at(irep, insn)
    where = op ? "#{op[:file]}:#{op[:line]}" : "#{irep.file} irep #{irep.label} insn #{insn.addr}"
    @disagreements << Row.new(kind: kind, where: where, annotated: annotated, derived: derived)
  end

  # At exit: the summary (stderr, with the other bc2cpp reports), and a failing status when any site disagreed.
  def hook!
    return if @hooked

    @hooked = true
    at_exit do
      warn CallRecords.summary unless CallRecords.checked.empty?
      exit 1 if !CallRecords.disagreements.empty? && ($!.nil? || ($!.is_a?(SystemExit) && $!.success?))
    end
  end

  def summary
    lines = ["== call records (BC2CPP_CALL_CROSSCHECK): #{@checked.values.sum} site(s) checked, #{@refinements.values.sum} refined, " \
             "#{@disagreements.size} disagree =="]
    @checked.sort.each { |kind, n| lines << "  #{kind}: #{n} checked, #{@refinements[kind]} refined by the record (the dataflow gave up)" }
    @disagreements.each { |r| lines << "  DISAGREE #{r.kind} #{r.where}: record #{r.annotated.inspect}, dataflow #{r.derived.inspect}" }
    lines.join("\n")
  end

  def reset!
    @disagreements.clear
    @refinements.clear
    @checked.clear
  end
end
