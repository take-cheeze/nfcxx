# frozen_string_literal: true

# The world pin policy of snapshot.rb (no oracle needed): a world at another commit whose inputs are unchanged passes (the pin is a
# note), a changed input fails, and when the pin also moved the missing inputs are one explanatory line, not one line each.
#   bundle exec ruby bc2cpp/tools/mrbc_rb/snapshot_test.rb
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'

ENV['BC2CPP_RPG_DIR'] = nil
require_relative 'golden_data'
require_relative 'snapshot'

S = MrbcRb::Snapshot
SCRIPT = File.expand_path('snapshot.rb', __dir__)
failures = 0
check = lambda do |name, ok, detail = nil|
  puts ok ? "ok   #{name}" : "FAIL #{name}#{detail ? ": #{detail}" : ''}"
  failures += 1 unless ok
end

git = ->(dir, *args) { system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', *args, out: File::NULL, err: File::NULL, exception: true) }

Dir.mktmpdir('snapshot_test') do |tmp|
  world = File.join(tmp, 'world')
  FileUtils.mkdir_p([File.join(world, '3rd/mruby/mrblib'), File.join(world, 'scripts')])
  File.write(File.join(world, '3rd/mruby/mrblib/a.rb'), "def a; 1; end\n")
  File.write(File.join(world, '3rd/mruby/mrblib/b.rb'), "def b; a + 2; end\n")
  File.write(File.join(world, 'scripts/x.rb'), "puts 'x'\n")
  git.call(world, 'init', '-q')
  git.call(world, 'add', '-A')
  git.call(world, 'commit', '-q', '-m', 'first')

  # the world table of that checkout, as --update would write it (value = what the emitter gives: no oracle here)
  ENV['BC2CPP_RPG_DIR'] = world
  table = {}
  S.each_input(world: world) do |_label, sources, scope|
    next unless scope == :world

    image = sources.size == 1 ? MrbcRb.compile(sources[0][0], sources[0][1]) : MrbcRb.compile_files(sources)
    table[S.key(sources)] = S.value(image)
  end
  table_file = File.join(tmp, 'snapshot_world.txt')
  S.write(table, ["# world: #{'0' * 40}\n", "# oracle: mruby test (0000000)\n"], table_file)

  run = lambda do
    Open3.capture2e({ 'BC2CPP_RPG_DIR' => world, 'BC2CPP_MRBC_SNAPSHOT_WORLD' => table_file }, RbConfig.ruby, SCRIPT, '--verify')
  end

  # another commit, same inputs
  File.write(File.join(world, 'README'), "bump\n")
  git.call(world, 'add', '-A')
  git.call(world, 'commit', '-q', '-m', 'bump')
  out, st = run.call
  check.call('a pin bump with unchanged inputs passes', st.success?, out[-300..])
  check.call('  and says so once', out.scan('world pin changed from 000000000000 to').size == 1 && out.include?('0 missing'), out[-300..])

  # a changed input fails; the pin that moved turns the missing lines into one
  File.write(File.join(world, '3rd/mruby/mrblib/b.rb'), "def b; a + 3; end\n")
  File.write(File.join(world, 'scripts/x.rb'), "puts 'y'\n")
  out, st = run.call
  missing = out.lines.grep(/not in snapshot/)
  check.call('a changed input fails', !st.success?, out[-300..])
  check.call('  with one summary line, not one per input',
             missing.size == 1 && missing.first.match?(/world pin changed from 000000000000 to \h{12}: \d+ inputs not in snapshot/) && out.lines.grep(/^MISSING/).empty?, out[-400..])

  # the same pin: the inputs are listed one by one
  git.call(world, 'add', '-A')
  git.call(world, 'commit', '-q', '-m', 'edit')
  pin = Open3.capture2('git', '-C', world, 'rev-parse', 'HEAD').first.strip
  S.write(table, ["# world: #{pin}\n", "# oracle: mruby test (0000000)\n"], table_file)
  out, st = run.call
  check.call('without a pin change the missing inputs are listed one each', !st.success? && out.lines.grep(/^MISSING/).size > 1 && !out.include?('world pin changed'), out[-300..])

  # a different value (emitter drift) fails whatever the pin
  bad = table.transform_values { |_v| '0' * 32 }
  S.write(bad, ["# world: #{'0' * 40}\n"], table_file)
  out, st = run.call
  check.call('a differing value fails', !st.success? && out.include?('DIFFERS'), out[-300..])
end

puts failures.zero? ? 'snapshot policy: all checks pass' : "#{failures} problem(s)"
exit(failures.zero? ? 0 : 1)
