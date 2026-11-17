#!/usr/bin/env ruby
# The macros of the -m options (nfcxx's isa block, docs/notes/driver-body-port.md): the macros gcc predefines with the -m options
# that gcc without them does not, each as the -D option that gives it to both the front end and the C compile. The bash ran
#   comm -13 <(gcc -dM -E -x c /dev/null | sort) <(gcc ISA... -dM -E -x c /dev/null | sort) \
#     | sed -n 's/^#define \([^ (]*\) */-D\1=/p'
# and this does the same: the two gcc runs (a failing gcc gives no lines, as the bash's process substitutions did), the sort
# (the locale's, as the bash's sort), the comm (the lines only in the second list, with their counts) and the sed rule (a macro
# with arguments is passed too, as the sed passes it). tests/driver-isa-macros/run.sh checks it against the bash verbatim.
#
#   ruby scripts/nfcxx-isa-macros.rb ISA...      one -D option per line on standard output; status 0
require "open3"

module NfcxxIsaMacros
  module_function

  # the sorted -dM lines of gcc with FLAGS (sort is the locale's, as in the bash)
  def macro_lines(flags)
    out, _status = Open3.capture2("gcc", *flags, "-dM", "-E", "-x", "c", "/dev/null", err: File::NULL)
    sorted, _ = Open3.capture2("sort", stdin_data: out)
    sorted.lines.map(&:chomp)
  rescue SystemCallError
    []
  end

  # comm -13 of two sorted lists: the lines of B that A does not have, each counted as often as it is in B and not in A
  def only_in_second(a, b)
    counts = Hash.new(0)
    a.each { |l| counts[l] += 1 }
    b.reject do |l|
      next false unless counts[l].positive?

      counts[l] -= 1
      true
    end
  end

  # sed -n 's/^#define \([^ (]*\) */-D\1=/p': the -D option of a #define line, nil for any other line
  def define_option(line)
    m = line.match(/\A#define ([^ (]*) */) or return nil
    "-D#{m[1]}=#{m.post_match}"
  end

  def options(isa)
    base = macro_lines([])
    with = macro_lines(isa)
    only_in_second(base, with).filter_map { |l| define_option(l) }
  end
end

if $PROGRAM_NAME == __FILE__
  NfcxxIsaMacros.options(ARGV).each { |o| puts o }
end
