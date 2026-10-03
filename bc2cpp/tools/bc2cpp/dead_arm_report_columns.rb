# frozen_string_literal: true

# The row layout of BC2CPP_DEAD_ARM_REPORT (dead_arm_report.rb), shared with scripts/bc2cpp_dead_arm_report.rb.
module DeadArmReport
  COLUMNS = %w[kind gem method irep idx op name shape live entry guard where origin path].freeze

  # kind: nomethod (a bc2cpp_nomethod arm), nil_receiver (a bc2cpp_nil_receiver arm), const_unresolved (a constant
  # nothing defines), arity_all / arity_some (a plain call whose every / some Ruby definition of the name rejects it).
  # partial_miss: a send whose proven receiver class set holds a non-nil class that does not answer the name (shape all: none
  # does; some: only part of the set), origin holds the classes.
  # shape (nomethod and nil_receiver only): chain (the arm is the else of a send with live arms), sole (the send has
  # no other arm), nil (the arm is the nil path of a nil-or-one-class receiver).
  # live: live | dead (the method body is not callable from any entry; the site can never run).
  # guard: - | rescue | probed | selfset (a store of a non-nil value to the receiver ivar precedes the read in one
  # straight-line stretch) | hint (a branch on the receiver's own value precedes the site; weak, it may guard only part).
  KINDS = %w[nomethod nil_receiver partial_miss const_unresolved arity_all arity_some].freeze
end
