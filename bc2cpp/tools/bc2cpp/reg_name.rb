# frozen_string_literal: true

# REG_NAME: a VM register's C++ name, `RegName[reg] == "r#{reg}"` for every value. The hottest emitters interpolate
# it instead of `r#{reg}`, so the common registers come from a frozen table rather than one Integer#to_s each.
module RegName
  NAMES = Array.new(256) { |reg| "r#{reg}".freeze }.freeze
  NUMBERS = NAMES.each_with_index.to_h.freeze

  def self.[](reg)
    (reg.is_a?(Integer) && reg >= 0 && NAMES[reg]) || "r#{reg}"
  end

  # The register `text` names ("r" and digits), else nil.
  def self.number(text)
    NUMBERS[text] || text[/\Ar(\d+)\z/, 1]&.to_i
  end
end
