# frozen_string_literal: true

# The command line of the fork's `mrbc`, as a library: MrbcRb::Cli.run(argv, stdin:, stdout:, stderr:, env:) -> exit status.
# bin/mrbc_rb is a thin wrapper over it; mruby_build.rb calls it in-process from mruby's rake. Nothing here calls exit, reads
# ENV or touches $stdout/$stderr directly: the streams and the environment are arguments (the fallback mrbc is a subprocess).
#
#   mrbc_rb [switches] programfile...
#
# Switches of mrbc.c and what this does with them:
#   -o<outfile> | -o <outfile>   implemented ("-" is stdout; required for several inputs, else the input's name with .mrb/.c)
#   -g                           implemented (debug info; the RITE binary the emitter makes)
#   -B<symbol> | -B <symbol>     implemented: C byte array (mrb_dump_irep_cfunc)
#   -S                           implemented with -B: the C struct dump (cdump.c); with -g only for one input file (see below)
#   -s                           implemented (static, for -B)
#   --remove-lv                  implemented (RITE binary without the LVAR section; cdump ignores it, as mrbc does)
#   -e, -E                       implemented (mrbc only prints "no longer needed" to stderr)
#   -c                           implemented (check syntax: "<prog>:<first input>:Syntax OK", by compiling with the emitter)
#   --version, --copyright, -h   implemented (the version text is the fork's: MRBC_RB_VERSION overrides it)
#   -v, --verbose, --no-ext-ops, --no-optimize, an input of "-" (stdin)
#                                not implemented here (-v/--verbose print the C parser's AST dump and the disassembly with
#                                the addresses of the irep structs); `--disasm` (an addition of this command) prints the instruction listing of -v alone, byte
#                                for byte what mrbc -v prints from its first `irep` line on, except the irep addresses (codedump.rb)
# Anything not implemented, a construct the emitter does not cover (MrbcRb::Unsupported), a source Prism rejects (mrbc then
# reports the syntax error itself) and an emitter crash is handed to the real mrbc named by MRBC_FALLBACK, run with
# the original arguments (its output and exit status are passed on). Without MRBC_FALLBACK the command fails (exit 1) and says what was not covered.
#
# -g with -S: cdump.c writes the symbol id of each file name, the number the symbol had in the C mrbc's symbol table. That is
# the presym count of the mrbc plus one for the first file, and for each further file it depends on what the lexer interned
# of the files before it: file_syms.rb reproduces it (MrbcRb::FileSyms), given the presym set of the mrbc build to match
# (MRBC_RB_PRESYM=fork|bootstrap|<file>, default: the fork's host mrbc, 1472 presyms; mruby's own bootstrap mrbc has 282).
#
# Environment:
#   MRBC_FALLBACK=<mrbc>   the real mrbc to run for what is not covered
#   MRBC_RB_PRESYM=fork|bootstrap|<file>   the presym set of the mrbc to match, for -g -S (see above)
#   MRBC_RB_LOG=<file>     one line per run: "<emitter|fallback|error>\t<reason>\t<args>"


require 'open3'
require_relative 'mrbc_rb'
require_relative 'rite_dump'
require_relative 'cdump'
require_relative 'file_syms'
require_relative 'codedump'

module MrbcRb
  class Cli
    class NotCovered < StandardError; end

    # Thrown (as the status) to leave #run from anywhere; never escapes it.
    class Exit < StandardError
      attr_reader :status

      def initialize(status)
        super("exit #{status}")
        @status = status
      end
    end

    USAGE = <<~USAGE
      switches:
      -c           check syntax only
      -o<outfile>  place the output into <outfile>; required for multi-files
      -v           print version number, then turn on verbose mode
      -g           produce debugging information
      -B<symbol>   binary <symbol> output in C language format
      -S           dump C struct (requires -B)
      -s           define <symbol> as static variable
      --remove-lv  remove local variables
      --no-ext-ops prohibit using OP_EXTs
      --no-optimize disable peephole optimization
      --verbose    run at verbose mode
      --version    print the version
      --copyright  print the copyright
    USAGE
    DEFAULT_VERSION = 'mruby 4.0.0 (2026-04-20)'
    COPYRIGHT_TEXT = 'mruby - Copyright (c) 2010-2026 mruby developers'

    # Runs the command; returns its exit status. +prog+ is what the messages call the program (mrbc prints argv[0]).
    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV, prog: $PROGRAM_NAME)
      new(argv, stdin, stdout, stderr, env, prog).run
    end

    def initialize(argv, stdin, stdout, stderr, env, prog)
      @argv = argv.map(&:to_s)
      @in = stdin
      @out = stdout
      @err = stderr
      @env = env
      @prog = prog
      @outfile = nil
      @initname = nil
      @dump_struct = @static = @debug = @no_lv = @check = @disasm = false
    end

    def run
      body
    rescue Exit => e
      e.status
    end

    private

    def finish(status) = raise(Exit.new(status))

    def log(served, reason = '-')
      path = @env.fetch('MRBC_RB_LOG', '')
      return if path.empty?

      File.open(path, 'a') { |f| f.puts [served, reason.to_s.tr("\n\t", '  '), @argv.join(' ')].join("\t") }
    end

    # Runs the real mrbc (MRBC_FALLBACK) with the original arguments; its output and status are this command's.
    def fallback(reason)
      real = @env.fetch('MRBC_FALLBACK', '')
      if real.empty?
        log('error', reason)
        @err.puts "#{@prog}: not handled by the Ruby emitter (#{reason}); set MRBC_FALLBACK=<mrbc> to run the real mrbc for it"
        finish 1
      end
      log('fallback', reason)
      stdin_data = @argv.include?('-') ? @in.read : nil
      begin
        out, err, st = Open3.capture3(real, *@argv, stdin_data: stdin_data, binmode: true)
      rescue SystemCallError => e
        @err.puts "#{@prog}: cannot run MRBC_FALLBACK (#{e.message})"
        finish 1
      end
      write_stream(@out, out)
      write_stream(@err, err)
      finish(st.exitstatus || (st.termsig ? 128 + st.termsig : 1))
    end

    def write_stream(io, data)
      io.binmode if io.respond_to?(:binmode)
      io.write(data)
    end

    # mrbc.c parse_args. Returns the index of the first input.
    def parse_args
      argv = @argv
      i = 0
      while i < argv.size
        arg = argv[i]
        break unless arg.start_with?('-')
        # "-" alone is an input (stdin); mrbc.c switches on arg[1], a NUL, and takes it as the default case.
        raise NotCovered, 'input from stdin' if arg == '-'

        case arg[1]
        when 'o'
          usage_error("an output file is already specified. (#{@outfile})") if @outfile
          if arg.size == 2 && argv[i + 1]
            i += 1
            @outfile = argv[i]
          else
            @outfile = arg[2..]
          end
        when 'S' then @dump_struct = true
        when 'B'
          if arg.size == 2 && argv[i + 1]
            i += 1
            @initname = argv[i]
          else
            @initname = arg[2..]
          end
          usage_error('function name is not specified.') if @initname.empty?
        when 'g' then @debug = true
        when 's' then @static = true
        when 'E', 'e' then @err.puts "#{@prog}: -e/-E option no longer needed."
        when 'c' then @check = true
        when 'h' then usage_error(nil)
        when 'v' then raise NotCovered, "option #{arg}"
        when '-'
          case arg
          when '--remove-lv' then @no_lv = true
          when '--version'
            @out.puts @env.fetch('MRBC_RB_VERSION', DEFAULT_VERSION)
            finish 0
          when '--disasm' then @disasm = true
          when '--copyright'
            @out.puts COPYRIGHT_TEXT
            finish 0
          when '--verbose', '--no-ext-ops', '--no-optimize' then raise NotCovered, "option #{arg}"
          else usage_error(nil)
          end
        else
          break # the default case of mrbc.c: the rest are inputs
        end
        i += 1
      end
      i
    end

    # mrbc.c: a bad option prints its message (stderr) and then the usage (stdout), exit status 1.
    def usage_error(msg)
      @err.puts "#{@prog}: #{msg}" if msg
      @out.puts "Usage: #{@prog} [switches] programfile..."
      USAGE.each_line { |l| @out.puts "  #{l}" }
      finish 1
    end

    def body
      first = begin
        parse_args
      rescue NotCovered => e
        fallback(e.message)
      end
      if first >= @argv.size
        @err.puts "#{@prog}: no program file given"
        finish 1
      end
      inputs = @argv[first..]
      fallback('-S without -B') if @dump_struct && !@initname
      if @outfile.nil? && !@check && !@disasm
        if inputs.size > 1
          @err.puts "#{@prog}: output file should be specified to compile multiple files"
          finish 1
        end
        @outfile = outfile_name(inputs.first, @initname ? '.c' : '.mrb')
      end
      unless File.file?(inputs.first) && File.readable?(inputs.first)
        @err.puts "#{@prog}: cannot open program file. (#{inputs.first})"
        finish 1
      end
      fallback('an input is not readable') unless inputs.all? { |f| File.file?(f) && File.readable?(f) }

      sources = inputs.map { |f| [File.binread(f), f] }
      compiled = begin
        MrbcRb.compile_files_result(sources)
      rescue MrbcRb::Error => e
        fallback("#{e.class.name.split('::').last}(#{e.message})")
      rescue StandardError => e
        fallback("Crash(#{e.class}: #{e.message[0, 100]})")
      end

      if @disasm
        write_stream(@out, MrbcRb::Codedump.listing(compiled.tree))
        finish 0
      end
      if @check
        @out.puts "#{@prog}:#{inputs.first}:Syntax OK"
        finish 0
      end

      out = begin
        render(compiled, sources)
      rescue MrbcRb::RiteDump::Unsupported, StandardError => e
        fallback("dump(#{e.class}: #{e.message[0, 100]})")
      end
      write(out)
      log('emitter')
      0
    end

    # The output for a MrbcRb::Result: -S from the irep tree, the others from the image.
    def render(compiled, sources)
      if @initname && @dump_struct
        file_syms = MrbcRb::FileSyms.ids(sources, set: MrbcRb::FileSyms.presyms(@env.fetch('MRBC_RB_PRESYM', 'fork'))) if @debug
        tree = MrbcRb::CDump.strip(compiled.tree, debug: @debug, lvar: true)
        MrbcRb::CDump.dump(tree, @initname, static: @static, file_syms: file_syms)
      else
        bin = MrbcRb::RiteDump.strip(compiled.image, debug: @debug, lvar: !@no_lv)
        @initname ? MrbcRb::CDump.cfunc(bin, @initname, static: @static) : bin
      end
    end

    def write(out)
      if @outfile == '-'
        write_stream(@out, out)
      else
        File.binwrite(@outfile, out)
      end
    rescue SystemCallError
      @err.puts "#{@prog}: cannot open output file:(#{@outfile})"
      finish 1
    end

    # get_outfilename: the input with its last '.' extension replaced (a dot in a directory name counts, as in the C).
    def outfile_name(infile, ext)
      dot = infile.rindex('.')
      dot ? infile[0...dot] + ext : infile
    end
  end
end
