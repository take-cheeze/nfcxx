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
# Sends that pass a block proc (the BLOCK instruction before them).
BLOCK_SEND = Set['SENDB', 'SSENDB'].freeze
# Sends whose receiver is self (the implicit-self form of each SEND variant).
SELF_SEND = Set['SSEND', 'SSEND0', 'SSENDB'].freeze
# Ops that write R(a) with the class a following METHOD/DEF defines into (vm.c OP_TCLASS, OP_SCLASS).
TARGET_CLASS = Set['TCLASS', 'SCLASS'].freeze
# Ops that allocate a fresh Array into R(a).
ARRAY_ALLOC = Set['ARRAY', 'ARRAY2'].freeze
# The self-receiver forms, including the splat forms. Named apart from SELF_SEND, whose membership is the master set.
SELF_SEND_FAMILY = Set['SSEND', 'SSEND0', 'SSENDB', 'SSENDV', 'SSENDVB'].freeze
# The sends that pass a block, splat forms included. Named apart from BLOCK_SEND, whose membership is the master set.
BLOCK_SEND_FAMILY = Set['SENDB', 'SSENDB', 'SENDVB', 'SSENDVB'].freeze
# The plain sends (SEND, SEND0, SENDB): arguments are a count, not a splat array as in SENDV.
COUNTED_SEND = (SEND - SELF_SEND_FAMILY).freeze
# Every send whose receiver is a register (the name prefix SEND, splat forms included).
REGISTER_RECEIVER_SEND = (SEND_FAMILY - SELF_SEND_FAMILY).freeze
# The zero-argument forms of SEND and SSEND.
ZERO_ARG_SEND = Set['SEND0', 'SSEND0'].freeze

    # Ops whose leading register is only READ and which may fall through (vm.c tests or raises on R(a));
    # SETUPVAR stores R(a) into an enclosing frame.
    READS_LEAD = Set['JMPIF', 'JMPNOT', 'JMPNIL', 'RAISEIF', 'MATCHERR', 'SETUPVAR'].freeze
    # READS_LEAD plus the frame exits that return R(a): every op whose leading register operand is read and never
    # written, so a backward writer walk may step over it.
    LEAD_READ_ONLY = (READS_LEAD | %w[RETURN RETURN_BLK BREAK]).freeze

    # A Range built from two endpoint registers.
    RANGE_BUILD = Set['RANGE_INC', 'RANGE_EXC'].freeze
    # Integer arithmetic with vm.c's integer arms; the I forms take an immediate second operand.
    INT_ARITH = Set['ADD', 'SUB', 'MUL', 'DIV', 'ADDI', 'SUBI'].freeze
    IMM_ARITH = Set['ADDI', 'SUBI'].freeze

    # Ops that leave the frame.
    FRAME_EXIT = Set['RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP'].freeze

    # Ops that write their leading register from their operands alone: no call, no implicit read.
    PURE_LOAD = Set['MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE'].freeze

    # Operand-widening prefixes `mrbc -v` lists as instructions of their own.
    EXT = Set['EXT1', 'EXT2', 'EXT3'].freeze
  end
end
