#!/usr/bin/env ruby
# encoding: UTF-8
# The mruby facts MODULE_SUPER_SUPPORT (ADR 0329) rests on, measured rather than
# assumed:
#
#   1. `super` from a class resolves INTO an included module, not the
#      superclass. This is why super_reaches_superclass? declines on any plain
#      `include`, and why resolving through the module is correct.
#   2. included modules are searched NEWEST-FIRST, so with two includes the last
#      one wins -- the order module_super_target walks.
#   3. a prepended module sits ABOVE the class, so a prepended `super` target
#      is not the one the class's own super reaches.
#   4. OP_SUPER forwards the caller's block: a block given to the re-defining
#      method reaches the module body that reads it. `(1..5).max { -b }` being
#      1 rather than 5 is the same fact seen from Range.
#
# If a future mruby searched differently, this fails here rather than silently
# mis-resolving a super in the compiler.
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

SRC = <<~'RUBY'
  module Mid
    def pick; 'mid'; end
  end
  module Other
    def pick; 'other'; end
  end
  class Base
    def pick; 'base'; end
  end
  class Sub < Base
    include Mid
    def pick; super; end
  end
  class Two < Base
    include Mid
    include Other
    def pick; super; end
  end
  module Pre
    def pick; 'pre'; end
  end
  class WithPre < Base
    include Mid
    prepend Pre
    def pick; super; end
  end
  class Deep < Sub
    def pick; 'deep->' + super; end
  end

  # OP_SUPER forwards the block: the module body reads it, so a nil would show.
  module Blk
    def pick(&block)
      block ? block.call(1, 2) : 'no-block'
    end
  end
  class BlkHost
    include Blk
    def pick(&block); super(&block); end
  end

  class Probe
    def go
      out = []
      out << "sub=#{Sub.new.pick}"
      out << "two=#{Two.new.pick}"
      out << "withpre=#{WithPre.new.pick}"
      out << "deep=#{Deep.new.pick}"
      out << "sub_ancestors=#{Sub.ancestors.include?(Mid) && Sub.ancestors.index(Mid) < Sub.ancestors.index(Base)}"
      out << "two_order=#{Two.ancestors.index(Other) < Two.ancestors.index(Mid)}"
      out << "pre_above=#{WithPre.ancestors.index(Pre) < WithPre.ancestors.index(WithPre)}"
      out << "blk=#{BlkHost.new.pick { |a, b| a + b }}"
      out << "blk_none=#{BlkHost.new.pick}"
      out.join("|")
    end
  end
RUBY

OWNERS = %w[Mid Other Base Sub Two Pre WithPre Deep Blk BlkHost Probe].freeze
SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    mrb_value r = mrb_funcall(M, probe, "go", 0);
    if (M->exc) { show_exc(M, "go"); return 0; }
    std::printf("%.*s\\n", (int)RSTRING_LEN(r), RSTRING_PTR(r));
    return 0;
  }
CPP

Dir.mktmpdir do |dir|
  code, err = runtime.generate(SRC, dir, closed: false, only_owners: OWNERS)
  built, output = runtime.run(dir, err, OWNERS, SCENARIO, build: full, full: true, vms: [false])
  check.call('the fixture builds against a full mruby', built)
  next unless built

  facts = output.split(/^== interpreted\n/).drop(1).first.to_s.strip
  puts "  #{facts}" unless facts.empty?
  check.call('a super reaches an included module, not the superclass', facts.include?('sub=mid'))
  check.call('included modules are searched newest-first', facts.include?('two=other'))
  check.call('the newest-first order holds in ancestors too', facts.include?('two_order=true'))
  check.call('a prepended module sits above the class', facts.include?('pre_above=true'))
  check.call('a prepended module wins the super, since it sits above the class',
             facts.include?('withpre=pre'))
  check.call('the module is above the superclass in ancestors',
             facts.include?('sub_ancestors=true'))
  check.call('a grandchild super walks the whole chain', facts.include?('deep=deep->mid'))
  check.call('OP_SUPER forwards the block to the module body', facts.include?('blk=3'))
  check.call('with no block the same super forwards nil', facts.include?('blk_none=no-block'))
end

abort "super ancestry: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp super ancestry check: PASS'
