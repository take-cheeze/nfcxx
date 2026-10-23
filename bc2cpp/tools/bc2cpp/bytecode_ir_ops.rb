# frozen_string_literal: true

require 'set'

# The one home of opcode-meaning sets (mruby ops.h / vm.c): what an op does to
# its leading register and whether it is a call. A pass that needs one of these
# meanings names the set here instead of spelling its own copy; an analysis-
# specific set (one op added or removed for that analysis) is built from these.
module BytecodeIR
  module Ops
    # Method sends: R(a) is the receiver, the callee frame starts at R(a).
    SEND = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'].freeze
    # Every op whose name starts with SEND or SSEND: SEND plus the splat forms (SENDV takes its arguments as an
    # array). A pass matching the name prefix uses this set, so the splat forms are not dropped.
    SEND_FAMILY = (SEND | %w[SENDV SENDVB SSENDV SSENDVB]).freeze
    # SEND plus SUPER: every op that dispatches a method by name.
    CALL = (SEND | ['SUPER']).freeze
    # Every op whose callee frame starts at R(a) and may overwrite R(a) and above.
    CALLEE_FRAME = (CALL | %w[EXEC BLKCALL]).freeze
    # Sends that take a block register after their arguments (vm.c OP_SENDB, OP_SSENDB).
    BLOCK_SEND = Set['SENDB', 'SSENDB'].freeze
    # Sends with no receiver register: the implicit-self forms.
    SELF_SEND = Set['SSEND', 'SSEND0', 'SSENDB'].freeze
    # Sends whose receiver is R(a): the complement of SELF_SEND within SEND.
    RECEIVER_SEND = (SEND - SELF_SEND).freeze
    # Ops that open a class or module body by name (`CLASS R :Name`, `MODULE R :Name`).
    CLASS_MODULE = Set['CLASS', 'MODULE'].freeze
    # Index reads R(a) = R(b)[...]: an index op, not a method send, so no SEND set holds it.
    INDEX_READ = Set['GETIDX', 'GETIDX0'].freeze
    # Ops that make a Proc from a literal block body of the current irep.
    LITERAL_PROC = Set['BLOCK', 'LAMBDA'].freeze

    # Ops whose leading register is only READ and which may fall through (vm.c tests or raises on R(a));
    # SETUPVAR stores R(a) into an enclosing frame.
    READS_LEAD = Set['JMPIF', 'JMPNOT', 'JMPNIL', 'RAISEIF', 'MATCHERR', 'SETUPVAR'].freeze
    # READS_LEAD plus the frame exits that return R(a): every op whose leading register operand is read and never
    # written, so a backward writer walk may step over it.
    LEAD_READ_ONLY = (READS_LEAD | %w[RETURN RETURN_BLK BREAK]).freeze

    # Ops that leave the frame.
    FRAME_EXIT = Set['RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP'].freeze

    # Ops that write their leading register from their operands alone: no call, no implicit read.
    PURE_LOAD = Set['MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE'].freeze

    # Operand-widening prefixes `mrbc -v` lists as instructions of their own.
    EXT = Set['EXT1', 'EXT2', 'EXT3'].freeze
  end
end
