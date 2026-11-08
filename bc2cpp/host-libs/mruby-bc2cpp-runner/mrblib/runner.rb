# The command's entry. The baked entry (tools/bc2cpp/bc2cpp.rb) runs its main block only when $PROGRAM_NAME is its own
# baked name, so the runner names it that way and requires it. ARGV is the command line, as the caller set it.
module BC2CPPRunner
  ENTRY = 'tools/bc2cpp/bc2cpp'.freeze
  DEBUG_SOURCES = %w[escape_report cha_self_report guard_hint_report interface_table_report send_root_report site_origin_table
                     refine_report native_arms_report provable_error_report element_site_report receiver_proof_report
                     param_trace else_trace recv_trace].map { |n| "tools/bc2cpp/#{n}" }.freeze
  DEBUG_MODULES = %w[EscapeReport ChaSelfReport GuardHintReport InterfaceTableReport SendRootReport SiteOriginTable RefineReport
                     NativeArmsReport ProvableErrorReport ElementSiteReport ReceiverProofReport ParamTrace ElseTrace
                     RecvTrace].freeze

  def self.run
    $PROGRAM_NAME = ENTRY
    if respond_to?(:register_compiled)
      # A host that linked bc2cpp's compiled code (docs/bc2cpp-self-compile.md): load the baked sources, replace their methods
      # with the compiled bodies, then run the command.
      Object.const_set(:BC2CPP_DEFER_MAIN, true)
      require ENTRY
      # Sources the entry loads only on demand own compiled methods too: the registration needs their classes.
      MRubyRequire.baked_names.each { |name| require name unless DEBUG_SOURCES.include?(name) }
      # The report and trace modules the entry requires only under a BC2CPP_*_REPORT or _TRACE variable prepend themselves to
      # CodeGen and register at_exit writers: they stay unloaded, as under CRuby, and registration gets an inert module to
      # attach their compiled methods to.
      DEBUG_MODULES.each { |name| Object.const_set(name, Module.new) unless Object.const_defined?(name) }
      register_compiled
      BC2CPP_MAIN.call
    else
      require ENTRY
    end
  ensure
    # bc2cpp writes its generated code from at_exit handlers (ShardOutput, CompactOutput capture stdout and emit at exit).
    ExitHandlers.run
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
