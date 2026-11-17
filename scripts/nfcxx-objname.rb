#!/usr/bin/env ruby
# nfcxx's object names for -c without -o (docs/notes/driver-body-port.md). The driver named each object by
# b=$(basename "$f"); ${b%.*}.o (C++ and .cu-free paths), and $(basename "$f" .c).o for C sources. This prints the same
# names, one per input line, so the driver can name all its objects in one call. tests/driver-objname/run.sh checks the
# port against the bash expressions verbatim.
#
#   printf '%s' NAME | ruby scripts/nfcxx-objname.rb              ${basename%.*}.o for NAME
#   printf '%s' NAME | ruby scripts/nfcxx-objname.rb --suffix=.c   $(basename NAME .c).o for NAME
#
# One name per run: standard input is the whole name (a name may contain a newline, so it is not split). The driver calls
# it once per object and checks the status (the call is in $(...) || exit $?).
#
# basename follows GNU basename: trailing slashes are dropped, and "/" stays "/". The default stem is the text before the
# last dot (so ".bashrc" gives ".o", "a.b.c" gives "a.b.o", "a." gives "a.o"). With --suffix, the suffix is removed only when
# it ends the name and is not the whole name (".c" stays ".c", so the object is ".c.o").

module NfcxxObjname
  module_function

  # GNU basename of PATH (a binary string)
  def basename(path)
    return "/".b if path.match?(%r{\A/+\z}n)

    stripped = path.sub(%r{/+\z}n, "".b)
    slash = stripped.rindex("/".b)
    slash ? stripped[(slash + 1)..] : stripped
  end

  # the object name for the input PATH; suffix nil is the ${b%.*} form, otherwise the basename NAME SUFFIX form
  def object_name(path, suffix: nil)
    base = basename(path.b)
    if suffix
      suf = suffix.b
      base = base[0...(base.bytesize - suf.bytesize)] if base.bytesize > suf.bytesize && base.end_with?(suf)
    else
      dot = base.rindex(".".b)
      base = base[0...dot] if dot
    end
    "#{base}.o".b
  end
end

if $PROGRAM_NAME == __FILE__
  suffix = nil
  ARGV.each do |arg|
    case arg
    when /\A--suffix=(.*)\z/m then suffix = Regexp.last_match(1)
    else
      warn "usage: nfcxx-objname.rb [--suffix=SUF] < name"
      exit 2
    end
  end
  name = $stdin.binmode.read
  $stdout.binmode.write(NfcxxObjname.object_name(name, suffix: suffix), "\n")
end
