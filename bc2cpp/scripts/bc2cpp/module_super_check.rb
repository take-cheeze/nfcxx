#!/usr/bin/env ruby
# encoding: UTF-8
# MODULE_SUPER_SUPPORT: `super` reaching an included module, with the current
# frame's block forwarded (ADR 0329).
#
# The real case is mruby's own Range: Range includes Enumerable and
# mruby-range-ext redefines #max/#min with `super(&block)`, which lands in
# Enumerable#max/#min -- bodies that DO read the block and are CORE_BLOCK_GUARDed
# because they yield (ADR 0269). Two things therefore have to hold, and this
# check is mostly about the second:
#
#   1. resolution -- `super` must be looked up through the included module, over
#      mruby's [class, modules newest-first, superclass] order, across BOTH the
#      engine registry and the compiled-core index (core owners are absent from
#      the former). mruby-range-ext's `super(&block)` is a plain `SUPER n=0`; a
#      bare `super` in a method with parameters is a zsuper (ARGARY + `SUPER
#      n=*`), a different shape that keeps its `#error`.
#   2. block forwarding -- a super that dropped the block would silently return
#      the wrong answer: `pick { |a,b| -b }` is 1, not 3. The emitted call must
#      carry this frame's block, and a guard-protected body may only be reached
#      when the build proved it yield-free.
#
# The Fiber cases live in bc2cpp_module_super_fiber_check.rb: putting a
# `Fiber.new` call to `pick` in this same world would make every pick
# "reachable from a Fiber.new block", which is its own (correct) refusal and
# would mask what is being measured here.
require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
# The fixture's `Ms#pick` iterates a literal Array with a block, so the
# behavioural half needs the full-core gems, not the core-only build.
full_build = runtime.full || runtime.full_or_build
failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

# Ms stands in for Enumerable, Hst for Range. Both declare `&block` and read
# it, which is what makes the forwarded block observable.
BASE = <<~'RUBY'
  module Ms
    def pick(&block)
      best = nil
      [1, 2, 3].each do |x|
        if block
          best = x if best.nil? || block.call(x, best) > 0
        else
          best = x if best.nil? || x > best
        end
      end
      best
    end
  end

  class Hst
    include Ms
    def pick(&block)
      return 100 if block.nil?

      super(&block)
    end
  end

  class HstNoBlock
    include Ms
    def pick
      super()
    end
  end

  module Mid
    def pick(&block); 'mid'; end
  end
  class Base
    def pick(&block); 'base'; end
  end
  class Sub < Base
    include Mid
    def pick(&block); super(&block); end
  end
  class SubPlain < Base
    def pick(&block); super(&block); end
  end

  class SupProbe
    def go
      out = []
      [Hst.new, Sub.new, SubPlain.new].each do |x|
        out << "#{x.class} plain=#{x.pick}"
        out << "#{x.class} first=#{x.pick { |a, b| a }}"
        out << "#{x.class} negate=#{x.pick { |a, b| -b }}"
      end
      out.join("\n")
    end
  end
RUBY

OWNERS = %w[Ms Hst HstNoBlock Mid Base Sub SubPlain SupProbe].freeze
require 'open3'
body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^\}$)/m].to_s }

# runtime.generate sets SKIP_UNSUPPORTED=1, which DROPS any method that still
# holds an #error -- so a body being empty is how "this one refused" shows up.
# To see the #error itself, compile once more without that flag.
generate_all = lambda do |source, owners|
  Dir.mktmpdir do |dir|
    src = File.join(dir, 'fixture.rb')
    File.write(src, source)
    env = { 'MRBC' => runtime.mrbc, 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => dir,
            'ONLY_OWNERS' => owners.join(',') }
    cmd = [RbConfig.ruby, File.join(File.expand_path('../..', __dir__), 'tools/bc2cpp/bc2cpp.rb'), '--annotated', src].shelljoin
    out, err, status = Open3.capture3(env, cmd)
    raise "bc2cpp.rb failed: #{err[-2000..]}" unless status.success?

    out
  end
end

SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "SupProbe"), 0, nullptr);
    // `go` builds each receiver's answers inside Ruby, so the blocks really
    // reach pick; call() cannot pass a block itself. Its one multi-line string
    // is printed verbatim: `show` would only inspect the whole thing.
    mrb_value r = (mrb_funcall_argv)(M, probe, mrb_intern_cstr(M, "go"), 0, nullptr);
    if (M->exc) { show_exc(M, "go"); return 0; }
    std::printf("%.*s\\n", (int)RSTRING_LEN(r), RSTRING_PTR(r));
    return 0;
  }
CPP

saved = ENV['BC2CPP_MODULE_SUPER']
begin
  ENV['BC2CPP_MODULE_SUPER'] = '0'
  off_all = generate_all.call(BASE, OWNERS)
  check.call('the kill switch keeps the #error at a super-through-a-module site',
             body.call(off_all, 'Hst_pick').include?('#error'))
  check.call('the kill switch #errors every super in this allowlist-free world',
             %w[Hst_pick Sub_pick SubPlain_pick].all? { |fn| body.call(off_all, fn).include?('#error') })

  ENV['BC2CPP_MODULE_SUPER'] = nil
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(BASE, dir, closed: false, only_owners: OWNERS)
    all = generate_all.call(BASE, OWNERS)
    hst = body.call(code, 'Hst_pick')
    check.call('a super through an included module no longer emits #error',
               !hst.empty? && !hst.include?('#error') && !body.call(all, 'Hst_pick').include?('#error'))
    check.call('the super call names the module method', hst.include?('Ms_pick_impl(M, self'))
    check.call("the frame's block is forwarded", hst.include?('Ms_pick_impl(M, self, bc2cpp_blk)'))
    check.call('a frame with no block slot keeps the #error when the target needs one',
               body.call(all, 'HstNoBlock_pick').include?('#error'))
    check.call('the newest included module wins over the superclass',
               body.call(code, 'Sub_pick').include?('Mid_pick_impl(M, self, bc2cpp_blk)'))
    check.call('an owner with no include still reaches its superclass',
               body.call(code, 'SubPlain_pick').include?('Base_pick_impl(M, self, bc2cpp_blk)'))
    check.call('the emitting path leaves no ARGARY behind', !hst.include?('ARGARY'))

    # Negative worlds: each must keep its own #error.
    zsuper = generate_all.call(BASE + "\nclass Zw\n  def pick(v = 0); super; end\nend\n", OWNERS + ['Zw'])
    check.call('a zsuper (ARGARY + SUPER n=*) keeps its #error',
               body.call(zsuper, 'Zw_pick').include?('#error'))
    shadow = generate_all.call("#{BASE}\nmodule Ms\n  def pick(&block); 'shadowed'; end\nend\n", OWNERS)
    check.call('two live definitions of the name on the module keep the #error',
               body.call(shadow, 'Hst_pick').include?('#error'))
    other = generate_all.call("#{BASE}\nmodule Ms2\n  def other(&block); 1; end\nend\nclass Hst; include Ms2; end\n",
                              OWNERS + ['Ms2'])
    check.call('a module without the name does not shadow the real target',
               body.call(other, 'Hst_pick').include?('Ms_pick_impl(M, self, bc2cpp_blk)'))

    built, output = if full_build
                  runtime.run(dir, err, OWNERS, SCENARIO, build: full_build, full: true, vms: [false, true, true])
                else
                  runtime.run(dir, err, OWNERS, SCENARIO, build: runtime.core, vms: [false, true, true])
                end
    check.call('fixture builds against real mruby', built)
    puts output if built
    sections = output.split(/^== (?:interpreted|compiled)\n/).drop(1)
    values = ->(s) { s.lines.reject { |l| l.start_with?('  ') }.join }
    check.call('values and exceptions match the interpreter across two compiled VMs',
               built && sections.size == 3 &&
               sections.drop(1).all? { |s| values.call(s) == values.call(sections.first) })
    first = sections.first.to_s
    check.call('the block provably reaches the module target (negate differs from first)',
               first.match?(/Hst first=3/) && first.match?(/Hst negate=1/))
    check.call('a nil block short-circuits before the super', first.match?(/Hst plain=100/))
    check.call('the newest-included-module order is observed at run time',
               first.match?(/^Sub plain=mid$/) && first.match?(/^SubPlain plain=base$/))
  end
ensure
  ENV['BC2CPP_MODULE_SUPER'] = saved
end

abort "module super: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp module super check: PASS'
