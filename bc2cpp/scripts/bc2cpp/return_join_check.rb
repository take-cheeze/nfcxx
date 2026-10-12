#!/usr/bin/env ruby
# encoding: UTF-8
# Check the RETURN-site join guard behind ARRAY_RETURN_PROOF and
# RETCLASS_SELF_CALL_SUPPORT (tools/bc2cpp/bc2cpp.rb's
# `straightline_return_reg?` / `return_write_dominates?`, ADR 0198): a write
# that dominates the RETURN may sit behind a jump target, but a write that
# some path skips (method entry's own nil/argument value, the other arm of a
# join, a nested block's SETUPVAR) must never prove the return class.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  class Foo; end
  class Baz; end
  class Probe
    def bar; end

    # Admitted: the write dominates the RETURN across an `if`/loop join.
    def dominated_foo(c)
      x = Foo.new
      bar if c
      x
    end
    def dominated_ary(c)
      x = []
      bar if c
      x
    end
    def loop_exit_ary(n)
      out = []
      i = 0
      while i < n
        out << i
        i += 1
      end
      out
    end
    # A grandchild's own-level SETUPVAR names the CHILD block's register, not
    # this method's, even when the register numbers coincide.
    def nested_block_ary(xs, _unused)
      hit = []
      xs.each do |x|
        a = 0
        b = 0
        [x].each { |y| b += y }
        hit << a
      end
      hit
    end

    # Refused: some path reaches the RETURN without executing the write.
    def maybe_foo(c)
      if c
        x = Foo.new
      end
      bar
      x
    end
    def maybe_ary(c)
      x = [] if c
      bar
      x
    end
    def opt_foo(a = Foo.new)
      bar
      a
    end
    def arg_then_write(a, c)
      a = Foo.new if c
      bar
      a
    end
    def either_foo
      @either || Foo.new
    end
    def loop_body_foo(n)
      while n > 0
        bar
        x = Foo.new
        n -= 1
      end
      x
    end
    # Refused: a nested block overwrites the returned local.
    def closure_write_foo
      x = Foo.new
      [1].each { x = 1 }
      x
    end
    def grandchild_write_foo
      x = Foo.new
      [1].each { [2].each { x = 1 } }
      x
    end
    # Refused: the `.dup` receiver is a join of two classes.
    def join_dup(c)
      x = Foo.new
      x = Baz.new if c
      x.dup
    end
  end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'return_join.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_return_join', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  # An empty foreign-method set (not nil) enables both return proofs.
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new, Set.new)
  arrays = gen.array_return_names
  classes = gen.class_return_names

  check.call('dominating write across an `if` proves the class', classes['dominated_foo'] == 'Foo')
  check.call('dominating write across an `if` proves Array', arrays.include?('dominated_ary'))
  check.call('RETURN on the loop-exit label still proves Array', arrays.include?('loop_exit_ary'))

  nested = registry['nested_block_ary'].first
  nested_irep = ireps.fetch(nested.irep)
  ret_reg = nested_irep.instructions.reverse.find { |insn| insn.op == 'RETURN' }.args[/\AR(\d+)/, 1]
  check.call('nested_block_ary really collides with a grandchild SETUPVAR register',
             gen.send(:subtree_upvar_written_regs, nested_irep).include?(ret_reg))
  check.call('a grandchild SETUPVAR of its own block does not block the proof', arrays.include?('nested_block_ary'))

  %w[maybe_foo opt_foo arg_then_write either_foo loop_body_foo closure_write_foo grandchild_write_foo
     join_dup].each do |name|
    check.call("#{name} is refused", !classes.key?(name))
  end
  check.call('maybe_ary is refused', !arrays.include?('maybe_ary') && !classes.key?('maybe_ary'))
end

if failures.empty?
  puts 'bc2cpp RETURN join guard check: PASS'
else
  warn "bc2cpp RETURN join guard check: #{failures.size} failure(s)"
  exit 1
end
