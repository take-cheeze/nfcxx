#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin census across exception flow (on by default; BC2CPP_SITE_ORIGIN_EXCEPTIONS=0
# turns it off, see SiteOriginTable::Writer.origin). A query the normal walk refuses inside a
# begin/rescue/ensure range is answered from the through_handlers walk, and that
# answer is taken only when it is one definition: the same writer on every normal
# and handler path. Hand-built shapes with fixed answers; codegen never reads the option.
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
unless defined?(CodeGen)
  # site_origin_table.rb prepends into CodeGen; the check needs only the writer.
  class CodeGen; end
end
require_relative '../../tools/bc2cpp/site_origin_table'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }

# [status, category, definition] the writer records for the query at +index+ of +reg+.
def writer_origin(list, handlers, index, reg, exceptions:)
  ENV['BC2CPP_SITE_ORIGIN_EXCEPTIONS'] = exceptions ? nil : '0'
  irep = Irep.new(label: 'origin_check', instructions: list, catch_handlers: handlers)
  SiteOriginTable::Writer.origin(irep, index, reg)
ensure
  ENV.delete('BC2CPP_SITE_ORIGIN_EXCEPTIONS')
end

# Positive: the send at index 2 (addr 4) reads R1, which the LOADI at index 0 defines before
# the range [2, 6). Its normal predecessor is a send on R2, whose callee frame sits at R2 and
# above and so cannot touch R1; the handler (addr 8) does not re-enter the range. The normal
# walk refuses at the protected send; the handler-aware walk answers with the one definition.
send_in_range = [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'SEND0', "R1\t:g"),
  insn(6, 'JMP', '10'), insn(8, 'LOADNIL', 'R2 (nil)'), insn(10, 'RETURN', 'R1')
]
range_handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 6, target: 8)]
check.call('a send in a range is answered from its one reaching definition with the option',
           writer_origin(send_in_range, range_handler, 2, '1', exceptions: true) ==
             ['exact', 'literal_or_fresh', 'LOADI_1@0'])
check.call('without the option the same send is refused, with the cause named',
           writer_origin(send_in_range, range_handler, 2, '1', exceptions: false) ==
             ['refused', 'query_guarded', '-'])

# Positive: the handler reads R1, below the lead (R3) of the send that raises into it. A callee
# frame at R3 cannot touch R1, so the handler's own read has the one definition.
handler_below = [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R3\t:f"), insn(4, 'JMP', '8'),
  insn(6, 'MOVE', 'R6\tR1'), insn(8, 'RETURN', 'R6')
]
below_handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 6, target: 6)]
check.call('a handler that reads a register below the raising call sees its one definition',
           writer_origin(handler_below, below_handler, 3, '1', exceptions: true) ==
             ['exact', 'literal_or_fresh', 'LOADI_1@0'])

# Negative (a raise path that changes the receiver): the raising send at index 1 writes R1 on
# completion, and the handler (addr 6) sends to R1. The value the handler is entered with is R1
# before the raise (the LOADI) or after the completed write (the send). Two definitions: unknown.
raise_changes_receiver = [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R1\t:f"), insn(4, 'JMP', '10'),
  insn(6, 'SEND0', "R1\t:g"), insn(8, 'NOP', ''), insn(10, 'RETURN', 'R1')
]
changes_handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 6, target: 6)]
check.call('a raise path that changes the receiver is a join (ambiguous with the may-set of both writers, not exact)',
           writer_origin(raise_changes_receiver, changes_handler, 3, '1', exceptions: true)  == ['ambiguous', 'call_result|literal_or_fresh', 'LOADI_1@0,SEND0@1'])

# Negative (the retry shape): the handler (addr 8) re-enters the second send. Its receiver R1 has
# the LOADI, the first send's completed write, and the second send's own completed write on the
# loop path: three definitions, unknown.
retry_loop = [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R1\t:f"), insn(4, 'SEND0', "R1\t:g"),
  insn(6, 'JMP', '12'), insn(8, 'JMP', '4'), insn(10, 'NOP', ''), insn(12, 'RETURN', 'R1')
]
retry_handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 8, target: 8)]
check.call('a handler that re-enters the send with a changed receiver is still ambiguous',
           writer_origin(retry_loop, retry_handler, 2, '1', exceptions: true)  == ['ambiguous', 'call_result|literal_or_fresh', 'LOADI_1@0,SEND0@1,SEND0@2'])

# Negative (a send whose receiver it writes itself, through a back edge): the loop carries the
# LOADI and the send's own result, so the receiver is never one definition.
self_write = [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R1\t:f"), insn(4, 'JMP', '2'), insn(6, 'NOP', ''),
  insn(8, 'RETURN', 'R1')
]
self_handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 6, target: 6)]
check.call('a send whose receiver it writes itself is still ambiguous',
           writer_origin(self_write, self_handler, 1, '1', exceptions: true)  == ['ambiguous', 'call_result|literal_or_fresh', 'LOADI_1@0,SEND0@1'])

# Negative (a callee frame above the handler's read): the send at addr 2 has its frame at R3, which
# may overwrite R5 before it raises into the handler that reads R5. Refused on every path, the
# clobber rule is the same with and without the option.
clobber_handler = [
  insn(0, 'LOADI_5', 'R5 (5)'), insn(2, 'SEND0', "R3\t:f"), insn(4, 'JMP', '8'),
  insn(6, 'MOVE', 'R6\tR5'), insn(8, 'RETURN', 'R6')
]
clobber_range = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 6, target: 6)]
check.call('a callee frame that may overwrite the register a handler reads stays refused',
           writer_origin(clobber_handler, clobber_range, 3, '5', exceptions: true) ==
             ['refused', 'callee_frame_clobber', '-'])

# A query with no handler at all is answered the same with and without the option.
plain = [insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R1\t:g"), insn(4, 'RETURN', 'R1')]
check.call('a send outside every range gets the same answer with and without the option',
           writer_origin(plain, [], 1, '1', exceptions: true) == writer_origin(plain, [], 1, '1', exceptions: false) &&
             writer_origin(plain, [], 1, '1', exceptions: false) == ['exact', 'literal_or_fresh', 'LOADI_1@0'])

if failures.empty?
  puts 'bc2cpp_site_origin_exceptions_check: ok'
else
  failures.each { |f| warn "FAIL #{f}" }
  exit 1
end
