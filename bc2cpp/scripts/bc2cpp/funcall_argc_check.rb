#!/usr/bin/env ruby
# encoding: UTF-8
# Check that no generated dynamic dispatch passes more than
# MRB_FUNCALL_ARGC_MAX (16) variadic arguments to mrb_funcall/mrb_funcall_id,
# which raise "Too long arguments. (limit=16)" at runtime past that. A
# literal-sized splat unrolls to one argument per element, so a wide
# constructor call went over it: `Game::Battle.from_actor`'s 22-field
# `Combatant.new(*[...])` failed every RPG2000 battle on the bc2cpp desktop
# build. Past the limit the call goes through mrb_funcall_argv, which packs
# 15+ arguments into a splat array itself.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

args = (1..20).map { |i| "a#{i}" }
SRC = <<~RUBY
  class Wide
    def initialize(*xs)
      @xs = xs
    end
  end

  class Builder
    def wide(#{args.join(', ')})
      Wide.new(*[#{args.join(', ')}])
    end

    def narrow(a, b)
      Wide.new(*[a, b])
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'funcall_argc.rb')
  File.write(path, SRC)
  ireps, root_label = compile_ireps(path, 'bc2cpp_funcall_argc', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = lambda do |name|
    gen.compile_method(registry.fetch(name).find { |d| d.owner == 'Builder' }.irep).fetch(:code)
  end

  wide = code.call('wide')
  counts = wide.scan(/mrb_funcall(?:_id)?\(M, \w+, (?:"[^"]*"|bc2cpp_sym\(M, \d+\)), (\d+)/).flatten.map(&:to_i)
  check.call('the 20-element splat compiles to a real call at all', wide.include?('mrb_funcall') || wide.include?('bc2cpp_funcall_argv'))
  check.call('no variadic mrb_funcall/mrb_funcall_id carries more than 16 arguments', counts.all? { |n| n <= 16 })
  check.call('the wide call goes through mrb_funcall_argv with all 20', wide.match?(/(?:mrb|bc2cpp)_funcall_argv\(M, \w+, [^;]*, 20, /))

  narrow = code.call('narrow')
  check.call('a narrow splat keeps the plain variadic mrb_funcall', narrow.match?(/(?:mrb_funcall|bc2cpp_funcall_explicit)\(M, \w+, "new", 2, /))
end

if failures.empty?
  puts 'bc2cpp funcall argc check: PASS'
else
  warn "bc2cpp funcall argc check: #{failures.size} failure(s)"
  exit 1
end
