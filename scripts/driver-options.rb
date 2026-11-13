#!/usr/bin/env ruby
# Option parsing for nfcc's driver, ported from the bash in nfcc (the port grows one function at a time; each function is
# checked against the bash it replaces by tests/nfcc/wp-option.sh). Written for bc2cpp as well as CRuby: byte strings, no
# Regexp, no File.readable?, no ENV.
#
# -Wp,a,b,c (the preprocessor options) is parsed by parse_wp_option. The ones with a plain meaning map to the option
# itself; any other is an error, because it would otherwise be dropped silently.
#
#   ruby scripts/driver-options.rb -Wp,OPTION...   prints the state the option sets, one line per fact:
#     pp <option>      a preprocessor option (-D, -U, -I, -isystem, ... given as separate words)
#     depmode <mode>   -MD or -MMD (the last one given)
#     dfile <file>     the dependency file (the last one given)
#     dt <option>      -MT or -MQ, then its target (two lines)
#     dp 1             -MP given
#   or, for a refused option, "nfcc: error: <message>" on stderr and status 1.

WpError = Class.new(StandardError)

# The state -Wp sets. Values are the same as the bash globals: pp, depmode, dfile, dts, dp.
WpState = Struct.new(:pp, :depmode, :dfile, :dts, :dp)

# Splits on commas the way bash's `IFS=, read -ra` does: an empty field in the middle is kept; a comma at the very end
# does not make an empty last field; an empty string gives no fields.
def split_wp_fields(text)
  fields = []
  field = "".b
  text.b.each_byte do |byte|
    if byte == 44 # ','
      fields << field
      field = "".b
    else
      field << byte
    end
  end
  fields << field unless field.empty?
  fields
end

# Parses one -Wp,... option into a WpState. Raises WpError with the message nfcc prints.
def parse_wp_option(option, state = WpState.new([], "", "", [], 0))
  words = split_wp_fields(option.b.byteslice(4, option.bytesize - 4))
  j = 0
  while j < words.length
    x = words[j]
    if x.bytesize > 2 && %w[-D -U -I].include?(x.byteslice(0, 2))
      state.pp << x
    elsif %w[-isystem -iquote -idirafter -include -imacros].include?(x)
      raise WpError, "#{option}: '#{x}' needs an argument" unless j + 1 < words.length

      j += 1
      state.pp << x << words[j]
    elsif %w[-MD -MMD].include?(x)
      raise WpError, "#{option}: '#{x}' needs a file name" unless j + 1 < words.length

      j += 1
      state.depmode = x
      state.dfile = words[j]
    elsif x == "-MF"
      raise WpError, "#{option}: '-MF' needs a file name" unless j + 1 < words.length

      j += 1
      state.dfile = words[j]
    elsif %w[-MT -MQ].include?(x)
      raise WpError, "#{option}: '#{x}' needs a target" unless j + 1 < words.length

      j += 1
      state.dts << x << words[j]
    elsif x == "-MP"
      state.dp = 1
    else
      raise WpError, "#{option}: the preprocessor option '#{x}' is not supported " \
                     "(only -D -U -I -isystem -iquote -idirafter -include -imacros -MD -MMD -MF -MT -MQ -MP)"
    end
    j += 1
  end
  state
end

def main(argv)
  state = parse_wp_option(argv[0].to_s)
  state.pp.each { |x| $stdout.write("pp #{x}\n") }
  $stdout.write("depmode #{state.depmode}\n") unless state.depmode.empty?
  $stdout.write("dfile #{state.dfile}\n") unless state.dfile.empty?
  state.dts.each_slice(2) { |flag, target| $stdout.write("dt #{flag} #{target}\n") }
  $stdout.write("dp 1\n") if state.dp == 1
  0
rescue WpError => e
  $stderr.write("nfcc: error: #{e.message}\n")
  1
end

rc = main(ARGV)
exit(rc) if rc != 0
