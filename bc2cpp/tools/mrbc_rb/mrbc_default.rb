# frozen_string_literal: true

# The mrbc a tool runs when MRBC is unset: bin/mrbc_rb, the Ruby emitter with the fork's mrbc command line.
# What the emitter does not cover goes to MRBC_FALLBACK; when that is unset, the first mrbc on PATH is used
# (never this wrapper). With no mrbc on PATH, such an input fails and says so (see cli.rb).
module MrbcRbDefault
  WRAPPER = File.expand_path('bin/mrbc_rb', __dir__)

  # The command a tool runs as mrbc.
  def self.command
    WRAPPER
  end
end
