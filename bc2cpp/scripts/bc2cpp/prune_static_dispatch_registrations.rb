#!/usr/bin/env ruby
# encoding: UTF-8
# Keeps the hand-written register.cxx lines in step with the unregistration
# lists. The generated registration (bc2cpp.rb's emit_owner_registrations)
# already skips listed names itself; this does the same for the hand-maintained
# lines. Needs no mrbc: a line is touched only when BOTH its name literal is the
# listed method's name AND its entry symbol is the one bc2cpp.rb's own cpp_name
# spells for that owner (codegen.rb's sanitize: `:` and `.` become `_`, any
# other non-identifier byte `$<hex>`), so a mismatch can only ever leave a line
# in place, never take the wrong one.
#
#   (default)  tools/bc2cpp/static_dispatch_unregistered.rb, which holds in every
#              build: the line is removed.
#   --closed   tools/bc2cpp/static_dispatch_unregistered_closed.rb, which only the
#              closed build applies (HAND_REGISTRATION_GUARD): the line is wrapped
#              in `#ifndef BC2CPP_UNREGISTERED_<entry>`. The generated code defines
#              that macro exactly in the builds whose list leaves the entry
#              unregistered, and a BC2CPP_UNREGISTERED_VERIFY build registers the
#              abort stub there instead.
#   --check    with --closed: change nothing, exit 1 if a listed line is not wrapped
#              or a wrapped line is no longer listed.
#
# Usage: ruby scripts/bc2cpp/prune_static_dispatch_registrations.rb [--closed [--check]]

require_relative '../../tools/bc2cpp/static_dispatch_unregistered'
require_relative '../../tools/bc2cpp/static_dispatch_unregistered_closed'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

# codegen.rb's sanitize / cpp_name.
def entry_symbol(owner, name)
  "#{owner}_#{name}".gsub(/[^a-zA-Z0-9_]/) { |c| ':.'.include?(c) ? '_' : format('$%02x', c.ord) }
end

def wanted(list)
  list.to_set do |key|
    owner, name = key.split('#', 2)
    [name, entry_symbol(owner, name)]
  end
end

LINE = /^([ \t]*)mrb_define_(private_|class_)?method\(\s*M\s*,\s*(\w+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*([A-Za-z_][A-Za-z0-9_$]*)\s*,[^;]*\);\n/m
GUARDED = /^#ifndef BC2CPP_UNREGISTERED_([A-Za-z_][A-Za-z0-9_$]*)\n(.*?)^#elif defined\(BC2CPP_UNREGISTERED_VERIFY\)\n.*?^#endif\n/m

root = File.expand_path('../..', __dir__)
closed = ARGV.include?('--closed')
check = ARGV.include?('--check')
abort '--check needs --closed' if check && !closed

if closed
  want = wanted(STATIC_DISPATCH_UNREGISTERED_CLOSED - STATIC_DISPATCH_UNREGISTERED)
  wrapped = 0
  stale = []
  missing = []
  StaticDispatchRegistrations::GEMS.each do |gem|
    path = File.join(root, gem, 'src', 'register.cxx')
    src = File.read(path, encoding: 'UTF-8')
    # Unwrap first: a guard whose entry left the list goes back to a plain line.
    out = src.gsub(GUARDED) do
      whole, entry, body = Regexp.last_match.values_at(0, 1, 2)
      line = body.match(LINE)
      key = line && [StaticDispatchRegistrations.unescape(line[4]), entry]
      if key && want.include?(key)
        whole
      else
        stale << "#{gem}: #{entry}"
        body
      end
    end
    out = out.gsub(LINE) do |line|
      m = Regexp.last_match
      indent, kind, var, name_lit, entry = m[1], m[2], m[3], m[4], m[5]
      already = m.pre_match.end_with?("#ifndef BC2CPP_UNREGISTERED_#{entry}\n")
      next line if already || !want.include?([StaticDispatchRegistrations.unescape(name_lit), entry])

      missing << "#{gem}: #{entry}"
      wrapped += 1
      stub = kind == 'class_' ? 'mrb_define_class_method' : 'mrb_define_method'
      "#ifndef BC2CPP_UNREGISTERED_#{entry}\n#{line}#elif defined(BC2CPP_UNREGISTERED_VERIFY)\n" \
        "#{indent}#{stub}(M, #{var}, \"#{name_lit}\", bc2cpp_unregistered_stub, MRB_ARGS_ANY());\n#endif\n"
    end
    File.write(path, out) if !check && out != src
  end
  if check
    problems = missing.map { |e| "listed but not wrapped: #{e}" } + stale.map { |e| "wrapped but not listed: #{e}" }
    abort "hand registration guards out of date (run without --check):\n  #{problems.join("\n  ")}" unless problems.empty?
    puts 'hand registration guards match the closed list'
  else
    puts "#{wrapped} hand registration line(s) wrapped, #{stale.size} unwrapped"
  end
  exit
end

want = wanted(STATIC_DISPATCH_UNREGISTERED)
removed = 0
StaticDispatchRegistrations::GEMS.each do |gem|
  path = File.join(root, gem, 'src', 'register.cxx')
  src = File.read(path, encoding: 'UTF-8')
  out = src.gsub(LINE) do |line|
    key = [StaticDispatchRegistrations.unescape(Regexp.last_match(4)), Regexp.last_match(5)]
    if want.include?(key)
      removed += 1
      ''
    else
      line
    end
  end
  File.write(path, out) unless out == src
end
puts "#{removed} hand registration line(s) removed"
