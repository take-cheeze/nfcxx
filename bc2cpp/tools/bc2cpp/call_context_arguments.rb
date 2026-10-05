# frozen_string_literal: true

require_relative 'numeric_flow'

# Mirrors strict OP_ENTER positional binding. Only the optional initializer slot
# selected by argc runs; omitted slots remain unknown until initialized.
module CallContextArguments
  Binding = Struct.new(:masks, :enter_edges, keyword_init: true)

  def self.bind(body, arguments)
    fields = body.enter&.enter_fields
    return nil unless fields && fields.size == 8 && fields.all? { |field| field.is_a?(Integer) && field >= 0 }

    required, optional, rest, post, keywords, keydict, block, = fields
    return nil unless [keywords, keydict, block, fields[7]].all?(&:zero?) && rest <= 1
    return nil if arguments.size < required + post
    return nil if rest.zero? && arguments.size > required + optional + post
    return nil if ENV['BC2CPP_CONTEXT_ARGUMENT_SHAPES'] == '0' && (optional.positive? || rest.positive? || post.positive?)

    supplied = [arguments.size - required - post, optional].min
    masks = arguments.take(required)
    masks.concat(arguments.slice(required, supplied))
    masks.concat(Array.new(optional - supplied, NumericFlow::OTHER))
    masks << NumericFlow::ARR if rest.positive?
    masks.concat(arguments.last(post)) if post.positive?
    index = body.instructions.index(body.enter)
    return nil unless index

    edges = {}
    if optional.positive?
      target = index + supplied + 1
      return nil unless body.instructions[index + 1, optional + 1]&.all? { |insn| insn.op == 'JMP' }
      return nil unless body.instructions[index + 1, optional + 1].size == optional + 1

      edges[index] = [target]
    end
    Binding.new(masks: masks, enter_edges: edges)
  end
end
