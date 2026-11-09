#!/usr/bin/env ruby
# frozen_string_literal: true

# StableClassConstants (tools/bc2cpp/const_site_cache.rb, CONST_SITE_CACHE) on host-compiled fixtures: a module
# reopened at one qualified path is one constant, so its reads are cached; a name opened at two paths, assigned, or
# named by a native source is not. Without the root irep the old rule (exactly one opener) applies. Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/const_site_cache_check.rb

require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/integer_constants'
require_relative '../../tools/bc2cpp/const_site_cache'

suite = FixtureCheck.new('const_site_cache_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  module Reopened
    module Inner; end
  end
  module Reopened
    class Leaf; end
  end
  module Reopened
    class Leaf; end
  end
  module Twice; end
  module Outer
    module Twice; end
  end
  module Assigned; end
  Assigned = 1
  module Once; end
  class NativeNamed; end
RUBY

Dir.mktmpdir('const-site-cache') do |dir|
  native = File.join(dir, 'native.c')
  File.write(native, "void init(mrb_state* mrb) { mrb_define_class(mrb, \"NativeNamed\", mrb->object_class); }\n")
  suite.compile(SOURCE) do |ireps, root_label|
    stable = StableClassConstants.analyze(ireps, [native], [], root_label)
    suite.check('a module reopened at one path is stable', stable.include?('Reopened'))
    suite.check('a class reopened at one nested path is stable', stable.include?('Leaf'))
    suite.check('a nested module opened once is stable', stable.include?('Inner') && stable.include?('Once'))
    suite.check('a name opened at two paths is not stable', !stable.include?('Twice'))
    suite.check('an assigned name is not stable', !stable.include?('Assigned'))
    suite.check('a name a native source defines is not stable', !stable.include?('NativeNamed'))
    legacy = StableClassConstants.analyze(ireps, [native], [])
    suite.check('without the root irep a reopened module is not stable (one opener)',
                !legacy.include?('Reopened') && legacy.include?('Once'))
  end
  suite.compile(<<~RUBY) do |ireps, root_label|
    module Mixed; end
    Mixed.const_set(:X, 1)
  RUBY
    stable = StableClassConstants.analyze(ireps, [native], [], root_label)
    suite.check('a program that calls const_set caches nothing', stable.empty?)
  end
end

suite.finish!
