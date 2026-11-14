#!/usr/bin/env ruby
# nfcxx's --target gate, ported from the bash in nfcxx: the checks that decide a --target build (the k1om block at
# "if [ "$target" = linux_k1om ]", the other-target block after it, and the checks before them that can end a target
# build: no input files, the EDG driver not built). See docs/notes/k1om.md.
#
#   ruby scripts/nfcxx-k1om.rb --facts=FILE ARG...
#
# prints "STATUS n" (the exit status the bash ends with) after a refusal the bash makes (n = 2, the bash's message on
# stderr; nothing is run before these refusals, so no other line is printed). An argument list the gate lets through, or
# one the port does not cover, exits 3 with "unported: ..." on stderr and prints nothing. A target-less argument list is
# unported: the rest of the driver is not ported here. The gate itself never runs a command: the bash exports
# NFCXX_GCC, NFCXX_AS and NFCXX_K1OM_ROOT for the compile that follows, which is unported.
#
# Accepted options (anything else is unported, so a refusal is never guessed): --freestanding, --emit-c, --backend=NAME,
# --target=NAME (the last one wins), --dialect=g++|clang, --gnu-version=N, -c, -o FILE, -std=c++NN|gnu++NN, -DX, -UX
# (also -D X, -U X), -WX, -w, -pipe, -O[0-3s], -g, -fwrapv, -fexceptions, -fno-strict-aliasing, -lNAME (not cuda).
# Inputs: .cc, .cpp, .cxx sources and .o objects; .a and .so are link inputs (not counted, as in the bash). Refused as unported: -I, -l of cuda, .c and other inputs, -E, -M,
# -fsyntax-only, -fsanitize=, --cosmo, --instantiate=, --trace=, --time-log=, --cache, --bundle-, --cuda-driver=,
# -x, -isystem, -include, -m*, -shared, -fPIC and every other option not listed.
#
# FILE holds the facts the bash reads from the machine (tests/nfcxx-k1om/run.sh writes it):
#   eccp 0|1             ${EDG}/eccp is executable (scripts/setup-edg.sh built the EDG driver)
#   k1om-gcc 0|1         $NFCXX_K1OM_ROOT/bin/k1om-mpss-linux-gcc is executable (default /opt/k1om)
#   k1om-libc 0|1        ROOT/build/k1om/libC.a is a file (scripts/setup-k1om.sh)
#   edg-table NAME       ROOT/build/edg-base/lib_NAME is a directory (one line per table)
#   module PATH          PATH declares or imports a C++ module (the module check reads the source; not ported)
#
# Assumed, not read: the environment (NFCXX_* variables; the harness runs the bash with none, so NFCXX_BACKEND is
# unset and the default backend is gcc under a target), the host dialect (g++ unless the host C++ compiler is clang,
# and the dialect check passes), the tools the driver builds (ensure_tool finds them fresh).

require "pathname"

class NfcxxUnported < StandardError
end

# a refusal the bash makes: its message, and its status
class NfcxxExit < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end

def unported(what)
  raise NfcxxUnported, what
end

def refuse(message)
  raise NfcxxExit.new("nfcxx: #{message}", 2)
end

class Facts
  attr_reader :tables, :modules

  def initialize(values, tables, modules)
    @values = values
    @tables = tables
    @modules = modules
  end

  def self.load(path)
    values = {}
    tables = []
    modules = []
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")

      key, rest = line.split(" ", 2)
      case key
      when "edg-table" then tables << rest.to_s
      when "module" then modules << Pathname.new(rest.to_s).cleanpath.to_s
      else values[key] = rest.to_s
      end
    end
    new(values, tables, modules)
  end

  def flag?(key)
    @values[key] == "1"
  end
end

class Gate
  def initialize(facts)
    @facts = facts
    @freestanding = false
    @emit_c = false
    @backend = nil
    @target = ""
    @srcs = []
    @nobj = 0
    @cfiles = 0
  end

  def run(argv)
    parse(argv)
    unported("no --target: the rest of the driver is not ported") if @target.empty?
    refuse("no input files") if @srcs.size + @nobj + @cfiles == 0
    refuse("EDG not built; run scripts/setup-edg.sh") unless @facts.flag?("eccp")
    @srcs.each do |s|
      unported("#{s} declares or imports a module (not ported)") if @facts.modules.include?(Pathname.new(s).cleanpath.to_s)
    end
    if @target == "linux_k1om"
      k1om_gate
    else
      other_target_gate
    end
  end

  private

  def parse(argv)
    i = 0
    while i < argv.size
      a = argv[i]
      case a
      when "--emit-c" then @emit_c = true
      when "--freestanding" then @freestanding = true
      when /\A--backend=(.*)\z/ then @backend = Regexp.last_match(1)
      when /\A--target=(.*)\z/ then @target = Regexp.last_match(1)
      when /\A--dialect=(g\+\+|clang)\z/, /\A--gnu-version=\d+\z/, "-c", "-pipe", "-w" then nil
      when /\A-std=(gnu)?\+\+\w+\z/, /\A-std=c\+\+\w+\z/ then nil
      when /\A-[DU]./, /\A-W/, /\A-O[0-3s]?\z/, "-g", "-fwrapv", "-fexceptions", "-fno-strict-aliasing" then nil
      when "-D", "-U"
        refuse("#{a} needs an argument") if i + 1 >= argv.size
        i += 1
      when "-o"
        unported("-o without a file") if i + 1 >= argv.size
        i += 1
      when /\A-l(.+)\z/
        unported("-l with cuda") if Regexp.last_match(1).include?("cuda")
      when /\.(cc|cpp|cxx)\z/ then @srcs << a
      when /\.o\z/ then @nobj += 1
      when /\.(a|so)\z/ then nil   # link inputs: not counted as inputs (the bash's "no input files" check)
      else
        unported("option or input #{a}")
      end
      i += 1
    end
  end

  def k1om_gate
    refuse("--target=linux_k1om needs --freestanding (the host's C++ headers are GCC 13's, not k1om's)") unless @freestanding
    refuse("--target=linux_k1om uses the gcc backend (the k1om GCC)") if !@backend.nil? && @backend != "gcc"
    refuse("no k1om toolchain at NFCXX_K1OM_ROOT (default /opt/k1om; docs/notes/k1om.md)") unless @facts.flag?("k1om-gcc")
    refuse("no k1om runtime at ROOT/build/k1om/libC.a (run scripts/setup-k1om.sh)") unless @facts.flag?("k1om-libc")
    unported("linux_k1om passes the gate; the compile that follows (NFCXX_GCC=k1om-cc, NFCXX_AS, NFCXX_K1OM_ROOT) is not ported")
  end

  def other_target_gate
    refuse("--target needs --freestanding (the host's library headers are the host target's)") unless @freestanding
    refuse("--target needs --emit-c (the generated C is for the target; compile it with a cross compiler)") unless @emit_c
    refuse("no EDG target '#{@target}' (lib_* tables: #{@facts.tables.join(' ')})") unless @facts.tables.include?(@target)
    unported("EDG target #{@target} passes the gate; its --emit-c front-end run is not ported")
  end
end

def main(argv)
  facts_arg = argv.shift.to_s
  raise ArgumentError, "the first argument is --facts=FILE" unless facts_arg.start_with?("--facts=")

  Gate.new(Facts.load(facts_arg.delete_prefix("--facts="))).run(argv)
  $stdout.write("STATUS 0\n")
  0
rescue NfcxxExit => e
  $stderr.write("#{e.message}\n")
  $stdout.write("STATUS #{e.status}\n")
  e.status
rescue NfcxxUnported => e
  $stderr.write("unported: #{e.message}\n")
  3
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
