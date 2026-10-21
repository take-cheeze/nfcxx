# frozen_string_literal: true

require_relative 'compiled_gems'

# The row layout of BC2CPP_BLOCK_SEND_REPORT, the TSV the block-send writer emits.
module BlockSendReport
  ENGINE_GEMS = BC2CPP_CLOSED_WORLD_GEMS
  COLUMNS = %w[irep idx gem owner kind name argc shape existing facts fact_kind fact_set fact_usable entry free
               free_if_entry brk ret self_source arms why byname marker producer where guarded].freeze
end
