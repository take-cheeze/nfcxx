# frozen_string_literal: true

# The row layout of BC2CPP_REFINE_REPORT (refine_report.rb), shared with scripts/bc2cpp_refine_report.rb.
module RefineReport
  ENGINE_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
  COLUMNS = %w[irep idx gem method op name argc args existing byname else kept listed_n facts verdict set_size
               set_kind target_size target_kind set target usable single single_usable web web_verdict web_set_size
               web_usable web_kind web_set web_target where listed family sample].freeze
end
