#!/usr/bin/env ruby
# Run an mruby script with nfcxx's standalone interpreter: scripts/mrb.rb script.rb [args...]
# Builds it first with scripts/setup-mruby.sh when build/mruby-tool/bin/mruby is missing.
# The Ruby port of the bash launcher (its original is tests/helpers/oracle/mrb.sh): the same decisions, messages and
# exit statuses. MRB names the interpreter; it must be executable (nothing is built for it).
require_relative 'tool-ensure'

root = File.expand_path('..', __dir__)
mrb_env = ENV['MRB'].to_s
exe = mrb_env.empty? ? File.join(root, 'build/mruby-tool/bin/mruby') : mrb_env
unless File.executable?(exe)
  unless mrb_env.empty?
    $stderr.puts "mrb: #{mrb_env} is not executable"
    exit 1
  end
  setup = File.join(root, 'scripts/setup-mruby.sh')
  unless File.exist?(setup)
    $stderr.puts "#{setup}: No such file or directory"
    exit 1
  end
  exit 1 unless system([setup, setup], out: $stderr)
end
ToolEnsure.exec_program(exe, *ARGV)
