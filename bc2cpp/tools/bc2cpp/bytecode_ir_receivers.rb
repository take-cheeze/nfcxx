# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'

# Op sets the receiver-class trace (trace_new_target_walk in dispatch_targets.rb) dispatches on. Each set is
# the exact op names of one `case` arm it replaces, so `when Set` and a string `when` ask the same question.
# The arms are disjoint, so their order does not change an answer. Sets already in BytecodeIR::Ops are used
# from there; only the arms Ops has no set for are named here.
module BytecodeIR
  module Receivers
    # The walk steps over these: RESCUE (its write is the barrier's business) and the read-only ops, except
    # the conditional jumps the container phi merge must see.
    SKIP_OPS = ['RESCUE', *(Ops::LEAD_READ_ONLY - %w[JMPIF JMPNOT])].freeze
    RESCUE = Set['RESCUE'].freeze
    # A plain register copy, followed to its source.
    COPY = Set['MOVE'].freeze
    # GETIDX overwrites its receiver register; GETIDX0 reads it from a separate source.
    INDEX_READ_IN_PLACE = Set['GETIDX'].freeze
    # The plain-receiver send forms (SEND, SEND0) and the implicit-self forms (SSEND, SSEND0) the walk reads
    # `.new`, `.dup` and accessors through. SENDB is the block-carrying `.new` form.
    PLAIN_SEND = Set['SEND', 'SEND0'].freeze
    SELF_SEND = Set['SSEND', 'SSEND0'].freeze
    BLOCK_NEW_SEND = Set['SENDB'].freeze
    # A Hash literal (HASH); Array and Range literals are BytecodeIR::Ops::ARRAY_ALLOC and RANGE_BUILD.
    HASH_LITERAL = Set['HASH'].freeze
    # Reads of an ivar, an upvalue, a constant and a constant-path segment.
    IVAR_READ = Set['GETIV'].freeze
    UPVAR_READ = Set['GETUPVAR'].freeze
    CONST_READ = Set['GETCONST'].freeze
    CONST_PATH_SEGMENT = Set['GETMCNST'].freeze
    # The conditional jumps the container phi merge inspects.
    COND_JUMP = Set['JMPNOT', 'JMPIF'].freeze
  end
end
