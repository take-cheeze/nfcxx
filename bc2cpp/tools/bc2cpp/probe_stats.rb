# frozen_string_literal: true

# ProbeStats: counts for the cleanliness-probe machinery (compiles_clean?/block_core_clean?/probe_clean),
# behind BC2CPP_PROBE_STATS=1. Reported to stderr at exit. Zero overhead when off (one ENV check per count
# would still cost; callers check the flag via .enabled? — here inlined as a constant false unless set).
module ProbeStats
  ENABLED = ENV['BC2CPP_PROBE_STATS'] == '1'
  COUNTS = Hash.new(0)

  module_function

  def count(key)
    COUNTS[key] += 1 if ENABLED
  end

  def note_label(label)
    return unless ENABLED
    COUNTS[:labels] = {} unless COUNTS.key?(:labels)
    COUNTS[:labels][label] = true
  end

  def note_probe_label(label)
    return unless ENABLED
    COUNTS[:probe_labels] = {} unless COUNTS.key?(:probe_labels)
    h = COUNTS[:probe_labels]
    h[label] = (h[label] || 0) + 1
  end

  def report
    return unless ENABLED
    labels = COUNTS.delete(:labels) || {}
    probes = COUNTS.delete(:probe_labels) || {}
    warn "== probe stats =="
    warn "  distinct compile_method labels: #{labels.size}"
    top = probes.sort_by { |_, v| -v }.first(15)
    warn "  most-probed labels:"
    top.each { |l, v| warn "    #{v}x label=#{l}" }
    COUNTS.sort_by { |_, v| -v }.each { |k, v| warn "  #{k}: #{v}" }
  end
end
