#!/usr/bin/env ruby
# encoding: UTF-8
# EXPLICIT_BLOCK_ARG_DIRECT: an `&expr` send (`each_item(&blk)`, `map_items(&:name)`) whose
# call resolves to compiled code calls the callee's `_impl` with the block instead of
# mrb_funcall_with_block. The block is converted as OP_SENDB converts it (ensure_block:
# nil and a Proc pass, anything else goes through #to_proc), so a Symbol, a Method and an
# object with its own #to_proc still reach the callee as Procs, and a non-convertible value
# still raises TypeError at the site. A receiver the guard does not name keeps its owner call:
# `@a.each(&b)` inside a class that defines `each` itself still reaches Array#each.
require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

runtime = Bc2cppFixtureRuntime
full = runtime.full || runtime.full_or_build
abort 'needs a full-core mruby (BC2CPP_MRUBY_FULL, or rake + g++)' unless full

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

BASE = <<~'RUBY'
  class Item
    def initialize(n); @n = n; end
    def name; "i#{@n}"; end
    def double; @n * 2; end
  end

  class Doubler
    def to_proc; proc { |x| x.double + 1 }; end
  end

  class Bag
    def initialize; @items = [Item.new(1), Item.new(2), Item.new(3)]; end

    def each_item(&blk)
      return :no_block unless blk

      @items.each { |i| blk.call(i) }
      :done
    end

    def map_items
      return :no_block unless block_given?

      out = []
      @items.each { |i| out << yield(i) }
      out
    end

    def scaled(k, &blk)
      @items.map { |i| blk.call(i) * k }
    end

    def from_sym; map_items(&:name); end
    def from_method; map_items(&method(:label)); end
    def from_to_proc; map_items(&Doubler.new); end
    def from_nil; map_items(&nil); end
    def with_arg(k); scaled(k, &:double); end
    def forward(&blk); each_item(&blk); end
    def bad_block; map_items(&42); end
    def label(i); "<#{i.name}>"; end
  end

  # Its own `each` is the only Ruby definer of the name, so the chain guards on Ring; the else
  # must stay the owner call (Array, Hash, ...), not a proven NoMethodError.
  class Ring
    def initialize; @a = [4, 5]; end
    def each(&b); @a.each(&b); end
  end

  class BagProbe
    def go
      bag = Bag.new
      out = []
      out << "sym=#{bag.from_sym.inspect}"
      out << "method=#{bag.from_method.inspect}"
      out << "to_proc=#{bag.from_to_proc.inspect}"
      out << "nil=#{bag.from_nil.inspect}"
      out << "arg=#{bag.with_arg(10).inspect}"
      seen = []
      out << "forward=#{bag.forward { |i| seen << i.name }.inspect}:#{seen.inspect}"
      out << "forward_none=#{bag.forward.inspect}"
      ring = []
      Ring.new.each { |x| ring << x }
      out << "ring=#{ring.inspect}"
      out << "bad=#{begin; bag.bad_block.inspect; rescue TypeError => e; e.class.to_s; end}"
      out.join("\n")
    end
  end
RUBY

OWNERS = %w[Item Doubler Bag Ring BagProbe].freeze
body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^\}$)/m].to_s }
DIRECT = %w[from_sym from_method from_to_proc from_nil with_arg forward].freeze

SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "BagProbe"), 0, nullptr);
    mrb_value r = mrb_funcall(M, probe, "go", 0);
    if (M->exc) { show_exc(M, "go"); return 0; }
    std::printf("%.*s\\n", (int)RSTRING_LEN(r), RSTRING_PTR(r));
    return 0;
  }
CPP

saved = ENV['BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT']
begin
  ENV['BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT'] = '0'
  off_code, = runtime.generate(BASE, Dir.mktmpdir, only_owners: OWNERS)
  check.call('the kill switch keeps every &expr site on mrb_funcall_with_block',
             DIRECT.all? { |m| body.call(off_code, "Bag_#{m}").include?('mrb_funcall_with_block(') })
  ENV['BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT'] = nil

  Dir.mktmpdir do |dir|
    code, err = runtime.generate(BASE, dir, only_owners: OWNERS)
    DIRECT.each do |m|
      fn = body.call(code, "Bag_#{m}")
      check.call("Bag##{m} calls its callee's _impl with the converted block",
                 fn.include?('EXPLICIT_BLOCK_ARG') && fn.include?('mrb_type_convert(M, bc2cpp_ebarg_blk_') &&
                   fn.match?(/Bag_(map_items|each_item|scaled)_impl\(M, [^;]*bc2cpp_ebarg_blk_/) &&
                   !fn.include?('mrb_funcall_with_block('))
    end
    ring = body.call(code, 'Ring_each')
    check.call("Ring#each keeps the owner call for receivers the guard does not name",
               ring.include?('EXPLICIT_BLOCK_ARG') && ring.include?('/* CLOSED_WORLD owner-call: each */') &&
                 !ring.include?('bc2cpp_nomethod'))

    built, output = runtime.run(dir, err, OWNERS, SCENARIO, build: full, full: true, vms: [false, true, true])
    check.call('fixture builds against real mruby', built)
    puts output if built
    sections = output.split(/^== (?:interpreted|compiled)\n/).drop(1)
    values = ->(s) { s.lines.reject { |l| l.start_with?('  ') }.join }
    check.call('values and exceptions match the interpreter across two compiled VMs',
               built && sections.size == 3 &&
                 sections.drop(1).all? { |s| values.call(s) == values.call(sections.first) })
    first = sections.first.to_s
    check.call('&:sym runs through Symbol#to_proc', first.match?(/^sym=\["i1", "i2", "i3"\]$/))
    check.call('&method(:x) runs the Method', first.match?(/^method=\["<i1>", "<i2>", "<i3>"\]$/))
    check.call('a user #to_proc is called', first.match?(/^to_proc=\[3, 5, 7\]$/))
    check.call('&nil passes no block', first.match?(/^nil=:no_block$/))
    check.call('a positional argument stays in front of the block', first.match?(/^arg=\[20, 40, 60\]$/))
    check.call('a forwarded block parameter reaches the callee',
               first.match?(/^forward=:done:\["i1", "i2", "i3"\]$/) && first.match?(/^forward_none=:no_block$/))
    check.call('an Array receiver of a guarded name still runs Array#each', first.match?(/^ring=\[4, 5\]$/))
    check.call('a value with no #to_proc still raises TypeError', first.match?(/^bad=TypeError$/))
  end
ensure
  ENV['BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT'] = saved
end

abort "explicit block arg direct: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp explicit-block-arg-direct check: PASS'
