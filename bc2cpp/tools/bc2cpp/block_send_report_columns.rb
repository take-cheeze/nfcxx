# frozen_string_literal: true

# The row layout of the BC2CPP_BLOCK_SEND_REPORT TSV.
module BlockSendReport
  ENGINE_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
  COLUMNS = %w[irep idx gem owner kind name argc shape existing facts fact_kind fact_set fact_usable entry free
               free_if_entry brk ret self_source arms why byname marker producer where guarded].freeze
end
