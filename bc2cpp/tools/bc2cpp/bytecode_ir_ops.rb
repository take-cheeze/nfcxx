# frozen_string_literal: true

require 'set'

# The one home of opcode-meaning sets (mruby ops.h / vm.c): what an op does to
# its leading register and whether it is a call. A pass that needs one of these
# meanings names the set here instead of spelling its own copy; an analysis-
# specific set (one op added or removed for that analysis) is built from these.
module BytecodeIR
  module Ops
    # Method sends: R(a) is the receiver, the callee frame starts at R(a).
    SEND = Set[:SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB].freeze
    # Every op whose name starts with SEND or SSEND: SEND plus the splat forms (SENDV takes its arguments as an
    # array). A pass matching the name prefix uses this set, so the splat forms are not dropped.
    SEND_FAMILY = (SEND | %i[SENDV SENDVB SSENDV SSENDVB]).freeze
    # SEND plus SUPER: every op that dispatches a method by name.
    CALL = (SEND | [:SUPER]).freeze
    # Every op whose callee frame starts at R(a) and may overwrite R(a) and above.
    CALLEE_FRAME = (CALL | %i[EXEC BLKCALL]).freeze
# Sends that pass a block proc (the BLOCK instruction before them).
BLOCK_SEND = Set[:SENDB, :SSENDB].freeze
# Sends whose receiver is self (the implicit-self form of each SEND variant).
SELF_SEND = Set[:SSEND, :SSEND0, :SSENDB].freeze
# Sends whose receiver is R(a): the complement of SELF_SEND within SEND.
RECEIVER_SEND = (SEND - SELF_SEND).freeze
# Ops that write R(a) with the class a following METHOD/DEF defines into (vm.c OP_TCLASS, OP_SCLASS).
TARGET_CLASS = Set[:TCLASS, :SCLASS].freeze
# Ops that allocate a fresh Array into R(a).
ARRAY_ALLOC = Set[:ARRAY, :ARRAY2].freeze
# Ops that open a class or module body by name (`CLASS R :Name`, `MODULE R :Name`).
CLASS_MODULE = Set[:CLASS, :MODULE].freeze
# Index reads R(a) = R(b)[...]: an index op, not a method send, so no SEND set holds it.
INDEX_READ = Set[:GETIDX, :GETIDX0].freeze
# Ops that make a Proc from a literal block body of the current irep.
LITERAL_PROC = Set[:BLOCK, :LAMBDA].freeze
# The self-receiver forms, including the splat forms. Named apart from SELF_SEND, whose membership is the master set.
SELF_SEND_FAMILY = Set[:SSEND, :SSEND0, :SSENDB, :SSENDV, :SSENDVB].freeze
# The sends that pass a block, splat forms included. Named apart from BLOCK_SEND, whose membership is the master set.
BLOCK_SEND_FAMILY = Set[:SENDB, :SSENDB, :SENDVB, :SSENDVB].freeze
# The plain sends (SEND, SEND0, SENDB): arguments are a count, not a splat array as in SENDV.
COUNTED_SEND = (SEND - SELF_SEND_FAMILY).freeze
# Every send whose receiver is a register (the name prefix SEND, splat forms included).
REGISTER_RECEIVER_SEND = (SEND_FAMILY - SELF_SEND_FAMILY).freeze
# The zero-argument forms of SEND and SSEND.
ZERO_ARG_SEND = Set[:SEND0, :SSEND0].freeze

    # Ops whose leading register is only READ and which may fall through (vm.c tests or raises on R(a));
    # SETUPVAR stores R(a) into an enclosing frame.
    READS_LEAD = Set[:JMPIF, :JMPNOT, :JMPNIL, :RAISEIF, :MATCHERR, :SETUPVAR].freeze
    # READS_LEAD plus the frame exits that return R(a): every op whose leading register operand is read and never
    # written, so a backward writer walk may step over it.
    LEAD_READ_ONLY = (READS_LEAD | %i[RETURN RETURN_BLK BREAK]).freeze

    # A Range built from two endpoint registers.
    RANGE_BUILD = Set[:RANGE_INC, :RANGE_EXC].freeze
    # Integer arithmetic with vm.c's integer arms; the I forms take an immediate second operand.
    INT_ARITH = Set[:ADD, :SUB, :MUL, :DIV, :ADDI, :SUBI].freeze
    IMM_ARITH = Set[:ADDI, :SUBI].freeze

    # Ops that leave the frame.
    FRAME_EXIT = Set[:RETURN, :RETURN_BLK, :RETSELF, :RETNIL, :RETTRUE, :RETFALSE, :BREAK, :STOP].freeze

    # Ops that write their leading register from their operands alone: no call, no implicit read.
    PURE_LOAD = Set[:MOVE, :LOADL, :LOADSYM, :LOADNIL, :LOADSELF, :LOADTRUE, :LOADFALSE].freeze

    # Opcode-name sets from insn_decoder.rb's FORMATS table (the authoritative op list). They replace
    # start_with?('LOADI') / start_with?('SET') and the LOADI regexes at their call sites.
    # The 13 table names starting with LOADI.
    LOADI_OPS = Set[:LOADI8, :LOADINEG, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4,
                    :LOADI_5, :LOADI_6, :LOADI_7, :LOADI16, :LOADI32].freeze
    # The one-byte-immediate forms LOADI_0..LOADI_7 of the same table.
    LOADI_SLOT = Set[:LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7].freeze
    # LOADI_SLOT plus LOADI16 and LOADI32: what /\ALOADI(?:_\d+|16|32)?\z/ matches among the table names.
    # LOADI8, LOADINEG and LOADI__1 are not in it.
    LOADI_SLOT_OR_WIDE = (LOADI_SLOT | %i[LOADI16 LOADI32]).freeze
    # The 8 table names starting with SET (SETGV SETSV SETIV SETCV SETCONST SETMCNST SETUPVAR SETIDX).
    SET_OPS = Set[:SETGV, :SETSV, :SETIV, :SETCV, :SETCONST, :SETMCNST, :SETUPVAR, :SETIDX].freeze

    # Operand-widening prefixes `mrbc -v` lists as instructions of their own.
    EXT = Set[:EXT1, :EXT2, :EXT3].freeze

    # Name-test sets: each is the exact membership, over InsnDecoder::FORMATS, of an op-name test that used to
    # be a string prefix, suffix or regex. The SSEND/SS prefixes reuse SELF_SEND and the EXT prefix reuses EXT.
    # Every table name starting with LOAD (start_with?('LOAD'); also `/\ALOAD/` and the LITERAL_LOAD regex).
    LOAD_PREFIX_OPS = Set[:LOADL, :LOADI8, :LOADINEG, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3,
                          :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7, :LOADI16, :LOADI32, :LOADSYM, :LOADNIL,
                          :LOADSELF, :LOADTRUE, :LOADFALSE].freeze
    # The ops that write their leading register from their operands alone (the PURE_WRITES regex): the LOAD
    # family plus MOVE, the GET* reads, STRING, LAMBDA, BLOCK, METHOD, TCLASS and OCLASS.
    PURE_WRITE_OPS = Set[:MOVE, :GETGV, :GETSV, :GETIV, :GETCV, :GETCONST, :GETUPVAR, :STRING, :LAMBDA,
                         :BLOCK, :METHOD, :OCLASS, :TCLASS, :LOADL, :LOADI8, :LOADINEG, :LOADI__1,
                         :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7,
                         :LOADI16, :LOADI32, :LOADSYM, :LOADNIL, :LOADSELF, :LOADTRUE, :LOADFALSE].freeze
    # Every name starting with JMP, RETURN, BREAK, RAISE, STOP or EXEC (the closed-world STOP_OPS regex).
    STOP_PREFIX_OPS = Set[:JMP, :JMPIF, :JMPNOT, :JMPNIL, :JMPUW, :RAISEIF, :RETURN, :RETURN_BLK, :BREAK,
                          :EXEC, :STOP].freeze
    # Every name starting with a flow-changing prefix (the loop_installers FLOW_OPS regex).
    FLOW_PREFIX_OPS = Set[:JMP, :JMPIF, :JMPNOT, :JMPNIL, :JMPUW, :EXCEPT, :RESCUE, :RAISEIF, :RETURN,
                          :RETURN_BLK, :RETSELF, :RETNIL, :RETTRUE, :RETFALSE, :BREAK, :STOP].freeze
    # Literal-producing names for the loop_installers LOAD_TRUTHY regex: LOADI*, LOADL and STRING.
    LOAD_TRUTHY_OPS = Set[:LOADL, :LOADI8, :LOADINEG, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3,
                          :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7, :LOADI16, :LOADI32, :STRING].freeze
    # Every name starting with SEND (start_with?('SEND')): the register-receiver sends, without the SENDV splat forms.
    SEND_PREFIX_OPS = Set[:SEND, :SEND0, :SENDB].freeze
    # Every name ending in 0 (end_with?('0')). The table's LOADI_0 and GETIDX0 match too.
    ZERO_SUFFIX_OPS = Set[:LOADI_0, :GETIDX0, :SSEND0, :SEND0].freeze
    # Every name ending in B (end_with?('B')). SUB matches too, so this is a name test, not a block-send set.
    B_SUFFIX_OPS = Set[:SSENDB, :SENDB, :SUB].freeze
  end
end
