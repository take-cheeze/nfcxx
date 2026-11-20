#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_SET_SHARE (tools/bc2cpp/owner_set_share.rb): owner calls with the same method, level and owner list share
# one bc2cpp_owner_set.
#
#   1. the rewrite: two sites with one key share it; a different level, method or owner list, a single site, a site
#      with direct rows (BC2CPP_OWNERS_D) and another gem's same site do not; the owner list stays spelled;
#   2. a fixture generated with BC2CPP_OWNER_SET_SHARE=1, run on a full-core mruby against interpreted: sites that
#      share a set, called with receivers of alternating classes, a redefinition between calls, and a core method
#      made private after both sites ran it, answer as interpreted.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/owner_set_share_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/owner_set_share'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

site = ->(recv, mid, level, owners) { "  r1 = bc2cpp_owner_call(M, #{recv}, #{mid}, #{level}, BC2CPP_OWNERS(#{owners}), mrb_nil_value(), 0);\n" }
text = site.call('r2', 7, 2, '"Array", "String"') + site.call('r5', 7, 2, '"Array", "String"') +
       site.call('r2', 7, 0, '"Array", "String"') + site.call('r2', 8, 2, '"Array", "String"') +
       site.call('r2', 7, 2, '"Array"') + site.call('r2', 9, 1, '"Hash"') +
       "  r1 = bc2cpp_owner_call(M, r2, 7, 2, BC2CPP_OWNERS_D(BC2CPP_OWNER_DIRECT(\"Array\", Array_x, MRB_ARGS_NONE(), MRB_METHOD_PUBLIC_FL) BC2CPP_OWNER_DIRECT(\"String\", String_x, MRB_ARGS_NONE(), MRB_METHOD_PUBLIC_FL), \"Array\", \"String\"), mrb_nil_value(), 0);\n" * 2
out = OwnerSetShare.rewrite(text, 'gem_a')
lines = out.lines
k = OwnerSetShare.key('gem_a', '7', '2', 'BC2CPP_OWNERS("Array", "String")')
check.call('two sites with one key share it, the owner list still spelled',
           lines[0..1].all? { |l| l.include?("7, 2, BC2CPP_SHARED(0x#{k}, BC2CPP_OWNERS(\"Array\", \"String\")), mrb_nil_value()") })
check.call('another level, method or owner list does not', lines[2..4].none? { |l| l.include?('BC2CPP_SHARED') })
check.call('a single site keeps its own set', !lines[5].include?('BC2CPP_SHARED'))
check.call('sites with direct rows keep theirs', lines[6..7].none? { |l| l.include?('BC2CPP_SHARED') })
check.call("another gem's same site has another key", OwnerSetShare.key('gem_b', '7', '2', 'BC2CPP_OWNERS("Array", "String")') != k)
check.call('a text with nothing to share is returned as it is', OwnerSetShare.rewrite(lines[5], 'gem_a') == lines[5])
ENV['BC2CPP_OWNER_SET_SHARE'] = '0'
check.call('BC2CPP_OWNER_SET_SHARE=0 turns it off in a real build', !OwnerSetShare.enabled?(true))
ENV.delete('BC2CPP_OWNER_SET_SHARE')
check.call('a fixture does not share by default', !OwnerSetShare.enabled?(false) && OwnerSetShare.enabled?(true))

SOURCE = <<~RUBY
  class Probe
    def a(o); o.size; end
    def b(o); o.size; end
    def each_size(xs)
      t = 0
      xs.each { |x| t += a(x) + b(x) }
      t
    end
    def peek(o); o.pack('C*'); end
    def peek2(o); o.pack('C*'); end
  end
RUBY
OWNERS = %w[Probe].freeze

HARNESS = <<~'CPP'
  static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
  static int scenario(mrb_state* M) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    mrb_value mixed[] = { eval(M, "[[1, 2], 'abc', [3], 'de', {a: 1}]") };
    call(M, "alternating classes", probe, "each_size", 1, mixed);
    mrb_value ary[] = { eval(M, "[1, 2, 3]") };
    call(M, "a array", probe, "a", 1, ary);
    mrb_value str[] = { eval(M, "'xy'") };
    call(M, "b string", probe, "b", 1, str);
    call(M, "a string", probe, "a", 1, str);
    eval(M, "class String; def size = :redefined; end");
    call(M, "b string after redefinition", probe, "b", 1, str);
    call(M, "a string after redefinition", probe, "a", 1, str);
    mrb_value sec[] = { eval(M, "[65, 66]") };
    call(M, "peek public", probe, "peek", 1, sec);
    call(M, "peek2 public", probe, "peek2", 1, sec);
    eval(M, "class Array; private :pack; end");
    call(M, "peek2 private", probe, "peek2", 1, sec);
    call(M, "peek private", probe, "peek", 1, sec);
    return 0;
  }
CPP

abort 'SKIP: set MRBC' unless ENV['MRBC']
Dir.mktmpdir('owner-set-share') do |dir|
  ENV['BC2CPP_OWNER_SET_SHARE'] = '1'
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  shared = code.scan(/BC2CPP_SHARED\((0x\h+), /).flatten
  check.call("the two size sites and the two pack sites share (#{shared.tally.values.inspect})",
             shared.tally.values.sort == [2, 2])
  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    compiled = plain.call(sections['compiled'])
    interpreted = plain.call(sections['interpreted'])
    check.call('built and ran', built)
    check.call('compiled matches interpreted', !compiled.empty? && compiled == interpreted)
    check.call('a redefinition answers at both sites', compiled.count { |l| l.include?('after redefinition => :redefined') } == 2)
    check.call('private raises at both sites', compiled.count { |l| l.include?('private => raised NoMethodError') } == 2)
    warn output unless failures.empty?
  else
    puts '  SKIP run: no full-core mruby build'
  end
ensure
  ENV.delete('BC2CPP_OWNER_SET_SHARE')
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp owner set share check: PASS'
