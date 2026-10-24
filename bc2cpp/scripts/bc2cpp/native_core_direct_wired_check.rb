# frozen_string_literal: true

# Checks the generated core direct-call entries (tools/bc2cpp/native_core_direct_generated.rb, written by
# scripts/bc2cpp/native_core_direct_wire.rb): every one must verify against the mruby sources, and the committed
# generated file and core_direct.rbs must be fresh.
#
# NativeCoreDirect.audit drops an unverified entry silently at compile time (that is its design: an entry that no
# longer matches is never trusted), so a broken generated entry would otherwise just stop being used. This check makes
# that visible. It needs no clang: the entries are pinned to their bodies.
#
#   ruby scripts/bc2cpp/native_core_direct_wired_check.rb
require_relative '../../tools/bc2cpp/native_core_direct'

FAILED = []
def check(what, ok)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  FAILED << what unless ok
end

root = File.expand_path('../..', __dir__)
puts '== the generated entries against the mruby sources'
paths = %w[array string numeric].map { |f| File.join(root, "3rd/mruby/src/#{f}.c") }
if paths.all? { |p| File.file?(p) }
  result = NativeCoreDirect.audit(paths)
  NativeCoreDirect::GENERATED_ENTRIES.each do |entry|
    reason = result[entry]
    check("#{entry.owner}##{entry.name} verifies#{reason ? " (#{reason})" : ''}", reason.nil?)
  end
  check('every generated entry is listed in ENTRIES', NativeCoreDirect::GENERATED_ENTRIES.all? { |e| NativeCoreDirect::ENTRIES.include?(e) })
  # A generated call site is in another translation unit: its function must have external linkage. The audit cannot
  # see linkage, so this reads the definition's own line and the one before it.
  NativeCoreDirect::GENERATED_ENTRIES.each do |entry|
    function = entry.checks.first.first
    source = paths.find { |p| NativeCoreDirect.function_body(p, function) }
    lines = source ? File.read(source, encoding: 'UTF-8').lines : []
    at = lines.index { |l| l.match?(/^#{Regexp.escape(function)}\s*\(/) }
    external = !at.nil? && lines[[at - 2, 0].max...at].none? { |l| l.match?(/\bstatic\b/) }
    check("#{entry.owner}##{entry.name} calls #{function}, which has external linkage", external)
  end
else
  check('mruby core sources are present (3rd/mruby)', false)
end

puts '== the hand-audited entries against the native sources the closed world compiles with'
# These pin bodies across mruby core and its gems (Array#compact is mruby-array-ext's), so they are audited against the
# whole native source set; a drifted body would otherwise just stop being used.
require_relative '../../tools/bc2cpp/compiled_gems'
hand_paths = bc2cpp_rgss_native_srcs(root, 'closed') + core_native_srcs(File.join(root, '3rd/mruby')) +
             external_gem_native_srcs(root)
hand_result = NativeCoreDirect.audit(hand_paths)
(NativeCoreDirect::HAND_ENTRIES + NativeCoreDirect::KERNEL_ENTRIES + NativeCoreDirect::NUMERIC_CONVERSION_ENTRIES +
 NativeCoreDirect::INHERITED_ENTRIES).each do |entry|
  reason = hand_result[entry]
  check("#{entry.owner}##{entry.name}/#{entry.arity} verifies#{reason ? " (#{reason})" : ''}", reason.nil?)
end

puts '== the committed files'
check('core_direct.rbs matches the table (native_core_direct_sigs.rb --check)',
      system('ruby', File.join(root, 'scripts/bc2cpp/native_core_direct_sigs.rb'), '--check', out: File::NULL))

puts
if FAILED.empty?
  puts 'native_core_direct_wired_check: all checks passed'
else
  puts "native_core_direct_wired_check: #{FAILED.size} failure(s)"
  exit 1
end
