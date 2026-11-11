#!/usr/bin/env ruby
# encoding: UTF-8
# OPTIONAL_BLOCK_FRAME: a method with an optional argument AND a
# `&block` (`def permutation(n = size, &block)`) extracts `bc2cpp_blk` in its
# wrapper, exactly as `def each(&block)` does -- but frame_block_available?
# only recognised the latter, so a BLOCK_FALLBACK region inside the former was
# compiled with blk_available false and its body could not forward the block.
#
# The three methods this fixes all forward the method's own block from inside a
# nested block, which is what makes a dropped block observable:
#   Array#permutation   ary.permutation(n-1) { |c| yield result + c }
#   Enumerable#cycle    each { |*i| ...; yield(*i) }   /  ary.each { |i| yield(*i) }
#   File.foreach        self.open(file) { |f| f.each { |l| yield l } }
require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
full = runtime.full || runtime.full_or_build
abort 'needs a full-core mruby (BC2CPP_MRUBY_FULL, or rake + g++)' unless full

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

# The three real shapes, plus a control that must still refuse.
BASE = <<~'RUBY'
  class Perm
    def initialize; @items = [1, 2, 3]; end

    # `n = nil` plus `&block`: the CORE_BLOCK_OPT shape. The nested region
    # forwards the method's own block with a bare `yield` inside the inner
    # block -- the BLKPUSH (1) + BLKCALL shape that needs `needs_blk`, which is
    # what the fix supplies.
    def permutation(n = nil, &block)
      return [] unless block
      n ||= @items.size
      out = []
      @items.each do |i|
        out << ([i] + @items.reject { |x| x == i })
      end
      out = out.take(n) if n.positive?
      out.each do |p|
        yield p
      end
      out
    end

    # A second region in the same method, at the level-0 BLKPUSH shape.
    def each_with(n = nil, &block)
      return [] unless block

      seen = []
      @items.each do |i|
        next if n && i > n

        block.call(i)
        seen << i
      end
      seen
    end
  end

  class NoBlockFrame
    def call(n = nil, &block)
      return :none unless block

      block.call(n)
    end
  end

  # NESTED_BLOCK_FORWARD: the File.foreach shape. The `yield` sits two block
  # levels deep (inside `each` inside `open_with`), so its BLKPUSH is lv == 2 and
  # resolves to the enclosing REGION's block, not the method's.
  class Nest
    def initialize; @log = []; end
    attr_reader :log

    def open_with(&block)
      inner = [1, 2, 3]
      wrap(inner) do |got|
        block.call(got)
      end
    end

    def wrap(items, &block)
      items.each do |i|
        block.call(i * 10)
      end
      self
    end

    def run_foreach(&block)
      return 0 unless block

      open_with do |v|
        yield v
      end
      1
    end
  end

  class PermProbe
    def go
      out = []
      p = Perm.new
      out << "plain=#{p.permutation.inspect}"
      out << "block=#{p.permutation(2) { |x| x }.inspect}"
      out << "per_block=#{p.permutation { |x| x }.inspect}"
      out << "cycle=#{p.each_with.inspect}"
      out << "cycle_n=#{p.each_with(2).inspect}"
      out << "cycle_block=#{begin; r = []; p.each_with { |i| r << i }; r.inspect; rescue => e; e.class.to_s; end}"
      out << "noblock=#{NoBlockFrame.new.call.inspect}"
      out << "noblock_n=#{NoBlockFrame.new.call(7).inspect}"
      out << "noblock_b=#{NoBlockFrame.new.call(7) { |x| x * 2 }.inspect}"
      n = Nest.new
      seen = []
      n.run_foreach { |v| seen << v }
      out << "nest=#{seen.inspect}"
      out << "nest_ret=#{begin; Nest.new.run_foreach { |v| v }.inspect; rescue => e; e.class.to_s; end}"
      out << "nest_noblock=#{Nest.new.run_foreach.inspect}"
      out.join("\n")
    end
  end
RUBY

OWNERS = %w[Perm NoBlockFrame Nest PermProbe].freeze
body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^\}$)/m].to_s }

SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "PermProbe"), 0, nullptr);
    mrb_value r = mrb_funcall(M, probe, "go", 0);
    if (M->exc) { show_exc(M, "go"); return 0; }
    std::printf("%.*s\\n", (int)RSTRING_LEN(r), RSTRING_PTR(r));
    return 0;
  }
CPP

saved = ENV['BC2CPP_OPT_BLOCK_FRAME']
begin
  ENV['BC2CPP_OPT_BLOCK_FRAME'] = '0'
  off_code, = runtime.generate(BASE, Dir.mktmpdir, only_owners: OWNERS)
  check.call('the kill switch leaves the region uncompilable (the method is dropped whole)',
             body.call(off_code, 'Perm_permutation').empty? ||
               body.call(off_code, 'Perm_permutation').include?('#error'))
  ENV['BC2CPP_OPT_BLOCK_FRAME'] = nil

  Dir.mktmpdir do |dir|
    code, err = runtime.generate(BASE, dir, only_owners: OWNERS)
    perm = body.call(code, 'Perm_permutation')
    check.call('the optional-arg-and-block method compiles its nested region',
               !perm.empty? && !perm.include?('#error'))
    check.call('the nested region forwards the frame block',
               perm.include?('bc2cpp_blk') && perm.match?(/mrb_funcall_with_block/))
    check.call('no unhandled BLOCK/SENDB/SSENDB survives in it',
               !perm.include?('unhandled opcode'))

    built, output = runtime.run(dir, err, OWNERS, SCENARIO, build: full, full: true, vms: [false, true, true])
    check.call('fixture builds against real mruby', built)
    puts output if built
    sections = output.split(/^== (?:interpreted|compiled)\n/).drop(1)
    values = ->(s) { s.lines.reject { |l| l.start_with?('  ') }.join }
    check.call('values and exceptions match the interpreter across two compiled VMs',
               built && sections.size == 3 &&
               sections.drop(1).all? { |s| values.call(s) == values.call(sections.first) })
    first = sections.first.to_s
    check.call('the forwarded block really runs (a dropped one would raise NoMethodError)',
               first.match?(/^per_block=\[\[1, 2, 3\], \[2, 1, 3\], \[3, 1, 2\]\]$/))
    check.call('a block supplied at the call site reaches the nested each',
               first.match?(/^cycle_block=\[1, 2, 3\]$/))
    check.call('a no-block call is still nil, not a crash',
               first.match?(/^noblock=:none$/) && first.match?(/^noblock_n=:none$/))
    check.call('a block-only call still works', first.match?(/^noblock_b=14$/))
    check.call('a yield two block levels deep reaches the caller block',
               first.match?(/^nest=\[10, 20, 30\]$/))
    check.call('the nested yield returns normally, not a LocalJumpError',
               first.match?(/^nest_ret=1$/))
    check.call('the same method with no block is still a no-op',
               first.match?(/^nest_noblock=0$/))
  end
ensure
  ENV['BC2CPP_OPT_BLOCK_FRAME'] = saved
end

abort "optional block frame: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp optional-block-frame check: PASS'
