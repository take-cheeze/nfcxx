# frozen_string_literal: true

# Runs one bc2cpp tool under mruby, by the name it was baked under (tools/bc2cpp/bake_sources.rb): the tool's main
# block sees $PROGRAM_NAME equal to its baked name, as it does when run as a script.
#
#   mruby tools/bc2cpp/mruby_tool.rb TOOL [ARGS...]
#
# TOOL is a path under BC2CPP_ROOT (the repository root, set by tools/bc2cpp/mruby-ruby). Invoked through that wrapper
# by RbConfig.ruby, so every subprocess a bc2cpp run starts is an mruby run of a baked tool.
root = ENV['BC2CPP_ROOT']
raise 'mruby_tool: BC2CPP_ROOT is not set' unless root

tool = ARGV.shift
raise 'usage: mruby_tool.rb TOOL [ARGS...]' unless tool

name = tool.start_with?("#{root}/") ? tool[(root.size + 1)..-1] : tool
name = name[0...-3] if name.end_with?('.rb')
$PROGRAM_NAME = name
require name
