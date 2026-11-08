# The command's entry. The baked entry (tools/bc2cpp/bc2cpp.rb) runs its main block only when $PROGRAM_NAME is its own
# baked name, so the runner names it that way and requires it. ARGV is the command line, as the caller set it.
module BC2CPPRunner
  ENTRY = 'tools/bc2cpp/bc2cpp'.freeze

  def self.run
    $PROGRAM_NAME = ENTRY
    if respond_to?(:register_compiled)
      # A host that linked bc2cpp's compiled code (docs/bc2cpp-self-compile.md): load the baked sources, replace their methods
      # with the compiled bodies, then run the command.
      Object.const_set(:BC2CPP_DEFER_MAIN, true)
      require ENTRY
      # Sources the entry loads only on demand own compiled methods too: the registration needs their classes.
      MRubyRequire.baked_names.each { |name| require name }
      register_compiled
      BC2CPP_MAIN.call
    else
      require ENTRY
    end
  end

  # One baked tool, by the name it was baked under, as tools/bc2cpp/mruby_tool.rb does for bin/mruby: ARGV is
  # TOOL [ARGS...], TOOL a path under BC2CPP_ROOT (set by tools/bc2cpp/mruby-ruby) or a baked name.
  def self.run_tool
    root = ENV['BC2CPP_ROOT']
    raise 'mruby_tool: BC2CPP_ROOT is not set' unless root

    tool = ARGV.shift
    raise 'usage: mruby_tool.rb TOOL [ARGS...]' unless tool

    name = tool.start_with?("#{root}/") ? tool[(root.size + 1)..-1] : tool
    name = name[0...-3] if name.end_with?('.rb')
    $PROGRAM_NAME = name
    require name
    ExitHandlers.run
  end
end
