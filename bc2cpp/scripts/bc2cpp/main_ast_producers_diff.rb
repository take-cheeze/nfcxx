#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares the two producers of scripts/bc2cpp/main_ast.rb (BC2CPP_AST_PRODUCER=clang and =nfcxx, docs/notes/nfcxx-ast.md) on a
# host `main` and every real C++ unit of the closed world (each unit as `--unit` beside the main). The `roots` of the two
# manifests (what MainReachability reads) must agree as follows; any other difference exits 1:
#   refusals   identical.
#   names      identical, except a name only clang reports that is a libstdc++ / libc internal: a literal of the toolchain's own
#              headers (static_assert messages, `vector::_M_realloc_insert` throw strings of member-template patterns EDG does not
#              keep, the `""` of a folded `__builtin_nanf("")`). Such a name is accepted only when it cannot name a Ruby method
#              (empty, or has a space or `::`) and is not written as a string literal in any file of the program itself (the
#              manifest's dependencies outside the compiler's own include directories). nfcxx must report no name clang does not.
#   functions  identical, except implicit and template-injected names of the library. MainReachability reads `functions` only as
#              `<cpp_name(owner, method)>_impl` = `Owner_method_impl` (the owner is a class constant, so the name never starts with
#              an underscore): a differing identifier ending in `_impl` that does not start with one is a difference; `_Vector_impl`, `~Derived`, `_Bind<type-parameter-0-0 (...)>` and the
#              like cannot be one.
#
#   BC2CPP_WORLD_ROOT=/path/to/rpg-maker-clone ruby scripts/bc2cpp/main_ast_producers_diff.rb [--closed=DIR] [--main=HOST.cxx] [UNIT...]
# With no UNIT: every .cxx / .cpp / .cc source of NativeFnKinds.sources. The host main defaults to
# tests/bc2cpp/fixtures/main_ast_stl_host.cxx. A unit that neither producer parses (a missing submodule) is skipped; one that
# only one parses is a difference.
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'base_rbs_all'
require_relative 'native_fn_kinds'

TOOLCHAIN_DIRS = %r{\A/usr/(?:include/c\+\+|lib/gcc|lib/llvm-\d+|include/x86_64-linux-gnu/c\+\+)/}
MAIN_AST = File.expand_path('main_ast.rb', __dir__)
PRODUCERS = %w[clang nfcxx].freeze

closed = nil
main = File.expand_path('../../../tests/bc2cpp/fixtures/main_ast_stl_host.cxx', __dir__)
units = []
ARGV.each do |arg|
  if arg.start_with?('--closed=') then closed = arg.delete_prefix('--closed=')
  elsif arg.start_with?('--main=') then main = File.expand_path(arg.delete_prefix('--main='))
  else units << File.expand_path(arg)
  end
end
sources = if units.empty?
            NativeFnKinds.sources(closed).select { |path, _| path.match?(/\.(?:cxx|cpp|cc)\z/) }
          else
            units.map { |path| [path, BaseRbsAll.source_flags(path, closed)] }
          end
# The first case is the main on its own (no unit), then each unit beside the main.
cases = [[nil, []]] + sources

# Whether +name+ is written as a string literal in a program file (not one of the toolchain's own headers).
program_text = Hash.new { |h, path| h[path] = File.binread(path) }
literal_in_program = lambda do |name, deps|
  deps.any? { |path| !path.match?(TOOLCHAIN_DIRS) && program_text[path].include?("\"#{name}\"".b) }
end

run = lambda do |producer, unit, flags, dir|
  output = File.join(dir, "#{producer}.json")
  command = [RbConfig.ruby, MAIN_AST, main, output, *(unit ? ['--unit', unit] : []), '--', '-std=gnu++17', *flags]
  _out, err, status = Open3.capture3({ 'BC2CPP_AST_PRODUCER' => producer }, *command)
  status.success? ? JSON.parse(File.read(output)) : (err.lines.reverse.find { |l| l =~ /\S/ } || 'failed').strip
end

bad = 0
checked = 0
skipped = 0
cases.each do |unit, flags|
  label = unit ? File.basename(unit) : File.basename(main)
  Dir.mktmpdir('main-ast-diff') do |dir|
    results = PRODUCERS.to_h { |producer| [producer, run.call(producer, unit, flags, dir)] }
    failed = results.select { |_, r| r.is_a?(String) }
    if failed.size == PRODUCERS.size
      skipped += 1
      puts "SKIP #{label} (both fail: #{failed['nfcxx']})"
      next
    elsif failed.any?
      bad += 1
      puts "DIFF #{label}: only #{(PRODUCERS - failed.keys).join} parses (#{failed.map { |p, e| "#{p}: #{e}" }.join('; ')})"
      next
    end
    checked += 1
    clang = results['clang'].fetch('roots')
    nfcxx = results['nfcxx'].fetch('roots')
    deps = results.values.flat_map { |r| r.fetch('dependencies').keys }.uniq
    problems = []
    problems << "refusals differ: clang #{clang['refusals'].inspect} nfcxx #{nfcxx['refusals'].inspect}" unless clang['refusals'] == nfcxx['refusals']
    extra = nfcxx['names'] - clang['names']
    problems << "names only nfcxx reports: #{extra.first(5).inspect}" unless extra.empty?
    internal = []
    (clang['names'] - nfcxx['names']).each do |name|
      if (name.empty? || name.include?(' ') || name.include?('::')) && !literal_in_program.call(name, deps) then internal << name
      else problems << "name only clang reports and not a toolchain internal: #{name.inspect}"
      end
    end
    differing = (clang['functions'] | nfcxx['functions']) - (clang['functions'] & nfcxx['functions'])
    differing.each do |name|
      problems << "function #{name.inspect} differs and can be an owner's _impl" if name.match?(/\A[^_\W]\w*_impl\z/)
    end
    bad += problems.size
    puts format('%-28s %4d names (%d toolchain-internal only in clang), %4d functions (%d differ, none an owner _impl): %s', label,
                clang['names'].size, internal.size, clang['functions'].size, differing.size,
                problems.empty? ? 'ok' : "#{problems.size} problem(s)")
    problems.first(10).each { |problem| puts "  #{problem}" }
  end
end
puts "main_ast producers: #{checked} compared, #{skipped} skipped (both fail), #{bad} differences"
abort 'FAIL main_ast producers: nothing compared' if checked.zero?
exit(bad.zero? ? 0 : 1)
