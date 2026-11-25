#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative '../../tools/mrbc_rb/mrbc_default.rb'

# EVAL_STRING_FORMS: methods defined by a string eval (class_eval, module_eval, instance_eval with a String) are
# not in bc2cpp's closed-world registry, so a call to them from a compiled body takes the nomethod path, which falls
# back to a real dispatch. Measured against CRuby-style behaviour on real mruby: the interpreted and compiled runs
# print the same for each form below, including respond_to? on an eval-defined method. A block form is covered by
# define_method_check.rb and block_self_method_boundary_check.rb.
#
# Behaviour on real mruby (needs a full-core libmruby: BC2CPP_MRUBY_FULL, or rake and g++ with 3rd/mruby).
#
# Usage: BC2CPP_MRUBY_FULL=dir ruby scripts/bc2cpp/eval_string_forms_probe.rb
# A probe, not a registered check: the CI registry reads *_check.rb files and needs each one in the world's policy.

ENV['BC2CPP_SIG_DIRS'] = ''
require_relative 'fixture_runtime'

CASES = {
  'class_eval string' => [%w[CE8], <<~RUBY],
    class CE1; end
    CE1.class_eval("def ce_str; 1; end")
    class CE8; def go(o); o.ce_str; end; end
    puts CE8.new.go(CE1.new)
    puts 'end'
  RUBY
  'module_eval string' => [%w[CE7], <<~RUBY],
    module CE3; end
    module CE3; module_eval("def ce_mod; 3; end"); end
    class CE7; include CE3; def go(o); o.ce_mod; end; end
    puts CE7.new.go(CE7.new)
    puts 'end'
  RUBY
  'instance_eval string' => [%w[CE8], <<~RUBY],
    class CE5; end
    o = CE5.new
    o.instance_eval("def ce_ie; 5; end")
    class CE8; def go(o); o.ce_ie; end; end
    puts CE8.new.go(o)
    puts 'end'
  RUBY
  'respond_to? on an eval-defined method' => [%w[CE9], <<~RUBY],
    class CE1; end
    CE1.class_eval("def ce_str; 1; end")
    class CE9; def go(o); o.respond_to?(:ce_str); end; end
    puts CE9.new.go(CE1.new)
    puts 'end'
  RUBY
}.freeze

CASES.each do |label, (owners, source)|
  check = Bc2cppStepCheck.new("eval string forms: #{label}")
  check.generate(source, owners)
  check.behaviour(source)
  check.finish
end
