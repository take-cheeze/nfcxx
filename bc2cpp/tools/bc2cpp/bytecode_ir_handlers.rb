# frozen_string_literal: true

# Exception flow for BytecodeIR::Program, kept apart from the normal-flow
# graph in bytecode_ir.rb: a consumer opts in with `include_handlers: true`.
#
# Model: every instruction whose address is in a handler's [begin_addr,
# end_addr) may raise into that handler, so it gets an edge to the handler's
# `target`, tagged with the handler's kind (:rescue / :ensure). That
# over-approximates (most instructions in a range cannot raise), which only
# costs proofs. It does NOT model an exception that leaves the frame uncaught,
# nor RAISE/RAISEIF outside every range: see #every_path_reaches?.
module BytecodeIR
  # +src+ and +target+ are instruction indices; +handler+ is the CatchHandler.
  HandlerEdge = Struct.new(:src, :target, :kind, :handler, keyword_init: true)

  class Program
    attr_reader :catch_handlers

    # False when some handler's target is not an instruction, so the handler
    # edges are incomplete and no analysis may rely on them.
    def handlers_resolved?
      handler_edges
      @handlers_resolved
    end

    # Frozen HandlerEdges, grouped by handler in declaration order, each group
    # in instruction order.
    def handler_edges
      @handler_edges ||= begin
        @handlers_resolved = true
        edges = @catch_handlers.flat_map do |handler|
          target = @address_to_index[handler.target]
          unless target
            @handlers_resolved = false
            next []
          end

          @instructions.filter_map do |instruction|
            next unless instruction.addr >= handler.begin_addr && instruction.addr < handler.end_addr

            HandlerEdge.new(src: instruction.index, target: target, kind: handler.type, handler: handler).freeze
          end
        end
        edges.freeze
      end
    end

    # Addresses some handler resumes at, whether or not one is an instruction.
    def handler_target_addrs
      @handler_target_addrs ||= @catch_handlers.to_set(&:target).freeze
    end

    # Every address in some handler's range. Handler ranges are half-open, but
    # +inclusive_end+ also takes end_addr, for a barrier that must not trust
    # the instruction right after a range either.
    def handler_protected_addrs(inclusive_end: false)
      @handler_protected_addrs ||= {}
      @handler_protected_addrs[inclusive_end] ||= begin
        addrs = Set.new
        @catch_handlers.each do |handler|
          addrs.merge(inclusive_end ? handler.begin_addr..handler.end_addr : handler.begin_addr...handler.end_addr)
        end
        addrs.freeze
      end
    end

    # True when another handler's range overlaps +handler+'s (ends inclusive)
    # without one containing the other.
    def handler_partially_overlaps?(handler)
      @catch_handlers.any? do |other|
        next false if other == handler

        overlaps = other.begin_addr <= handler.end_addr && handler.begin_addr <= other.end_addr
        nested = (other.begin_addr <= handler.begin_addr && handler.end_addr <= other.end_addr) ||
                 (handler.begin_addr <= other.begin_addr && other.end_addr <= handler.end_addr)
        overlaps && !nested
      end
    end

    # Successor indices of +index+, plus its handler targets on request.
    def successors_of(index, include_handlers: false)
      normal = @instructions[index].successors
      return normal unless include_handlers

      @handler_successors ||= handler_edges.group_by(&:src).transform_values { |edges| edges.map(&:target) }
      extra = @handler_successors[index]
      extra ? (normal + extra).uniq : normal
    end

    # Set of indices reachable from +start+ (inclusive), never entering
    # +avoiding+ (which is excluded even as a start).
    def reachable_from(start, include_handlers: false, avoiding: nil)
      seen = Set.new
      return seen if start == avoiding

      work = [start]
      until work.empty?
        index = work.pop
        next unless seen.add?(index)

        successors_of(index, include_handlers: include_handlers).each do |successor|
          work << successor unless successor == avoiding
        end
      end
      seen
    end

    # Does every path from the method entry to +target_index+ pass through
    # +dominator_index+? false when +target_index+ is unreachable.
    def dominates?(dominator_index, target_index, include_handlers: false)
      return false if @instructions.empty?
      return false unless reachable_from(0, include_handlers: include_handlers).include?(target_index)
      return true if dominator_index == target_index

      !reachable_from(0, include_handlers: include_handlers, avoiding: dominator_index).include?(target_index)
    end

    # Does every path from +from+ that completes (ends at an instruction with
    # no NORMAL successor: RETURN, STOP, the last instruction...) pass through
    # +to+? Exits are judged on normal flow even with +include_handlers+: a
    # RETURN inside a handler range still leaves the method. An exception that
    # propagates out of the frame is not a path here, so callers that must also
    # cover it need the handler's own guarantee (ensure).
    def every_path_reaches?(from, to, include_handlers: false)
      return true if from == to

      reachable_from(from, include_handlers: include_handlers, avoiding: to).none? do |index|
        @instructions[index].successors.empty?
      end
    end
  end
end
