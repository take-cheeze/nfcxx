# frozen_string_literal: true

# In-process mrbc for mruby's own build. mruby's rake (lib/mruby/build/command.rb) runs `mrbc` for every gem's mrblib, the core
# mrblib and mrbtest's files through `MRuby::Command::Mrbc#run`, which spawns the command ~100 times; with bin/mrbc_rb that is
# one Ruby start-up and one Prism load per file (~0.2 s each). This file, required once from build_config.rb, prepends a
# `run` that calls MrbcRb::Cli.run in the rake process itself (one Prism load for the whole build), building the same
# command line and writing the same output. What the emitter does not cover goes to the real mrbc named by MRBC_FALLBACK,
# spawned by Cli (without MRBC_FALLBACK the build fails and names the file, as bin/mrbc_rb does).
#
#   # build_config.rb, before the MRuby::Build blocks (or inside one, before the first gem task runs):
#   require '/path/to/nfcxx/bc2cpp/tools/mrbc_rb/mruby_build'
#   MRuby::Build.new do |conf|
#     conf.mrbcfile = MrbcRb::MrubyBuild::WRAPPER   # keeps mruby from building its bootstrap mrbc; also the fallback for old rake
#     ...
#
# Only a build whose mrbc is that wrapper is served in-process; any other `mrbcfile` runs as before. MRBC_RB_PRESYM,
# MRBC_RB_LOG and MRBC_FALLBACK are read from ENV per call, as for the command.

require 'shellwords'
require 'stringio'
require_relative 'cli'

module MrbcRb
  module MrubyBuild
    WRAPPER = File.expand_path('bin/mrbc_rb', __dir__)

    def self.ours?(command)
      File.expand_path(command.to_s) == WRAPPER
    end

    # MRuby::Command::Mrbc#run, in-process.
    module InProcessRun
      def run(out, infiles, funcname, cdump: true, static: false)
        @command ||= @build.mrbcfile
        return super unless MrbcRb::MrubyBuild.ours?(@command)

        infiles = [infiles].flatten
        infiles.each_with_index { |f, i| _pp i == 0 ? 'MRBC' : '', f.relative_path, indent: 2 }
        opt = @compile_options % { funcname: funcname }
        opt << ' -S' if cdump
        opt << ' -s' if static
        argv = Shellwords.split(opt) + filename(infiles)
        puts "#{MrbcRb::MrubyBuild::WRAPPER} #{argv.shelljoin}" if Rake.verbose
        buf = StringIO.new.binmode
        status = MrbcRb::Cli.run(argv, stdin: StringIO.new, stdout: buf, stderr: $stderr, env: ENV, prog: MrbcRb::MrubyBuild::WRAPPER)
        unless status.zero?
          rm_f out.path
          fail "Command failed with status (#{status}): [#{WRAPPER[0, 42]}...]"
        end
        out.puts buf.string
      end
    end
  end
end

MRuby::Command::Mrbc.prepend(MrbcRb::MrubyBuild::InProcessRun) if defined?(MRuby::Command::Mrbc)
