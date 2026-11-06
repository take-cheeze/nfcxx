# The command's entry. The baked entry (tools/bc2cpp/bc2cpp.rb) runs its main block only when $PROGRAM_NAME is its own
# baked name, so the runner names it that way and requires it. ARGV is the command line, as the caller set it.
module BC2CPPRunner
  ENTRY = 'tools/bc2cpp/bc2cpp'.freeze

  def self.run
    $PROGRAM_NAME = ENTRY
    require ENTRY
  end
end
