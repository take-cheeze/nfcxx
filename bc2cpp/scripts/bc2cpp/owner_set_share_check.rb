#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_SET_SHARE (tools/bc2cpp/owner_set_share.rb): owner calls with the same method, level and owner list share
# one descriptor and bc2cpp_owner_set.
#
#   1. the rewrite: two sites with one key share it, defined once after the BC2CPP_SHARED macro; a different level,
#      method or owner list, a single site, a site with direct rows (BC2CPP_OWNERS_D) and another gem's same site do
#      not; the owner list stays spelled;
#   2. a fixture generated with BC2CPP_OWNER_SET_SHARE=1, run on a full-core mruby against interpreted: sites that
#      share a set, called with receivers of alternating classes, a redefinition between calls, and a core method
#      made private after both sites ran it, answer as interpreted;
#   3. OWNER_CALL_ARITY (tools/bc2cpp/owner_call_arity.rb), the pass after it on the same text: an owner call with no
#      block and at most two arguments, or a block and none, calls a fixed-arity entry. The rewrite of each shape (a
#      level 2 site keeps its caller self; a block with arguments, three arguments and the splat form stay general;
#      the owner-call comment stays), then a fixture generated with BC2CPP_OWNER_CALL_ARITY=1 run against
#      interpreted: each entry, a block, a private method's NoMethodError and a wrong argument count.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/owner_set_share_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/owner_set_share'
require_relative '../../tools/bc2cpp/owner_call_arity'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

site = ->(recv, mid, level, owners) { "  r1 = bc2cpp_owner_call(M, #{recv}, BC2CPP_OWNERS(#{mid}, #{level}, #{owners}), mrb_nil_value(), 0);\n" }
text = site.call('r2', 7, 2, '"Array", "String"') + site.call('r5', 7, 2, '"Array", "String"') +
       site.call('r2', 7, 0, '"Array", "String"') + site.call('r2', 8, 2, '"Array", "String"') +
       site.call('r2', 7, 2, '"Array"') + site.call('r2', 9, 1, '"Hash"') +
       "  r1 = bc2cpp_owner_call(M, r2, BC2CPP_OWNERS_D(7, 2, BC2CPP_OWNER_DIRECT(\"Array\", Array_x, MRB_ARGS_NONE(), MRB_METHOD_PUBLIC_FL) BC2CPP_OWNER_DIRECT(\"String\", String_x, MRB_ARGS_NONE(), MRB_METHOD_PUBLIC_FL), \"Array\", \"String\"), mrb_nil_value(), 0);\n" * 2
out = OwnerSetShare.rewrite(OwnerSetShare::DEFS_AT + text, 'gem_a')
k = OwnerSetShare.key('gem_a', '7', '2', '"Array", "String"')
defs = out[OwnerSetShare::DEFS_AT.size...out.index('  r1 = ')].lines
lines = out[out.index('  r1 = ')..].lines
check.call('two sites with one key share it, the slot, level and owner list still spelled',
           lines[0..1].all? { |l| l.include?("BC2CPP_SHARED(0x#{k}, 7, 2, \"Array\", \"String\"), mrb_nil_value()") })
check.call('the shared key is defined once, after the macro: names, zeroed set, descriptor',
           defs == ["inline const char* const bc2cpp_owner_sn_0x#{k}[] = { \"Array\", \"String\", nullptr };\n",
                    "inline bc2cpp_owner_set* bc2cpp_owner_ss_0x#{k}{};\n",
                    "inline const bc2cpp_owner_desc bc2cpp_owner_sd_0x#{k} = { bc2cpp_owner_sn_0x#{k}, nullptr, &bc2cpp_owner_ss_0x#{k}, 7, 2 };\n"])
check.call('another level, method or owner list does not', lines[2..4].none? { |l| l.include?('BC2CPP_SHARED') })
check.call('a single site keeps its own set', !lines[5].include?('BC2CPP_SHARED'))
check.call('sites with direct rows keep theirs', lines[6..7].none? { |l| l.include?('BC2CPP_SHARED') })
check.call("another gem's same site has another key", OwnerSetShare.key('gem_b', '7', '2', '"Array", "String"') != k)
check.call('a shared site with no macro to define it after is an error',
           begin
             OwnerSetShare.rewrite(text, 'gem_a')
             false
           rescue RuntimeError => e
             e.message.include?('OWNER_SET_SHARE')
           end)
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


puts '-- OWNER_CALL_ARITY (tools/bc2cpp/owner_call_arity.rb)'
set = 'BC2CPP_SHARED(0x1, BC2CPP_ARITY_OWNERS("Array", "String"))'
site = ->(tail) { "  r1 = bc2cpp_owner_call(M, r2, 7, 2, #{set}, #{tail}); /* CLOSED_WORLD owner-call: x */\n" }
rw = ->(tail) { OwnerCallArity.rewrite(site.call(tail)) }
want = ->(call) { "  r1 = #{call}; /* CLOSED_WORLD owner-call: x */\n" }
check.call('no block, no argument', rw.call('mrb_nil_value(), 0') == want.call("bc2cpp_owner_call0(M, r2, 7, 2, #{set})"))
check.call('a level 2 site keeps its caller self',
           rw.call('mrb_nil_value(), 0, self') == want.call("bc2cpp_owner_call0(M, r2, 7, 2, #{set}, self)"))
check.call('one argument', rw.call('mrb_nil_value(), 1, r3, self') == want.call("bc2cpp_owner_call1(M, r2, 7, 2, #{set}, r3, self)"))
check.call('two arguments', rw.call('mrb_nil_value(), 2, r3, r4') == want.call("bc2cpp_owner_call2(M, r2, 7, 2, #{set}, r3, r4)"))
check.call('a block and no argument', rw.call('bc2cpp_blk_stack_4.proc(), 0') ==
                                      want.call("bc2cpp_owner_call_b0(M, r2, 7, 2, #{set}, bc2cpp_blk_stack_4.proc())"))
check.call('a block with an argument keeps the general form',
           rw.call('bc2cpp_blk_stack_4.proc(), 1, r3') == site.call('bc2cpp_blk_stack_4.proc(), 1, r3'))
check.call('three arguments keep the general form', rw.call('mrb_nil_value(), 3, r3, r4, r5') == site.call('mrb_nil_value(), 3, r3, r4, r5'))
splat = "  r1 = bc2cpp_owner_call_argv(M, r2, 7, 0, #{set}, mrb_nil_value(), n, argv);\n"
check.call('the splat form is left alone', OwnerCallArity.rewrite(splat) == splat)
nested = "  r1 = bc2cpp_owner_call(M, r2, 7, 0, BC2CPP_ARITY_OWNERS_D(BC2CPP_OWNER_DIRECT(\"A,(\", A_x, MRB_ARGS_REQ(1), " \
         "MRB_METHOD_PUBLIC_FL) \"A\"), mrb_nil_value(), 1, bc2cpp_int(M, (1, 2)));\n"
check.call('nested parentheses and a string with a comma',
           OwnerCallArity.rewrite(nested) == nested.sub('bc2cpp_owner_call(', 'bc2cpp_owner_call1(').sub('mrb_nil_value(), 1, ', ''))
desc = "  r1 = bc2cpp_owner_call(M, r2, BC2CPP_OWNERS(7, 2, \"Array\"), mrb_nil_value(), 1, r3, self);\n"
check.call('the descriptor form (OWNER_CALL_DESC) gets its entry too',
           OwnerCallArity.rewrite(desc) == "  r1 = bc2cpp_owner_call1(M, r2, BC2CPP_OWNERS(7, 2, \"Array\"), r3, self);\n")
defn = "static mrb_value bc2cpp_owner_call(mrb_state* M, mrb_value recv, int i, int level, bc2cpp_owner_set& s, mrb_value blk, mrb_int argc, ...) {\n"
check.call("the variadic entry's definition is left alone", OwnerCallArity.rewrite(defn) == defn)
ENV['BC2CPP_OWNER_CALL_ARITY'] = '0'
check.call('BC2CPP_OWNER_CALL_ARITY=0 turns it off in a real build', !OwnerCallArity.enabled?(true))
ENV.delete('BC2CPP_OWNER_CALL_ARITY')
check.call('a fixture keeps the general form by default', !OwnerCallArity.enabled?(false) && OwnerCallArity.enabled?(true))

ARITY_SOURCE = <<~RUBY
  class Probe
    def zero(o); o.size; end
    def one(o, x); o.push(x); end
    def two(o, i, x); o.insert(i, x); end
    def blk(o); t = 0; o.each { |x| t += x }; t; end
    def three(o); o.insert(1, 2, 3); end
    def peek(o); o.pack('C*'); end
  end
RUBY
ARITY_OWNERS = %w[Probe].freeze

ARITY_HARNESS = <<~'CPP'
  static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
  static int scenario(mrb_state* M) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    mrb_value a1[] = { eval(M, "[1, 2, 3]") };
    call(M, "zero array", probe, "zero", 1, a1);
    mrb_value s1[] = { eval(M, "'xy'") };
    call(M, "zero string", probe, "zero", 1, s1);
    mrb_value a2[] = { eval(M, "[1, 2, 3]"), mrb_fixnum_value(4) };
    call(M, "one", probe, "one", 2, a2);
    mrb_value s2[] = { eval(M, "'ab'"), mrb_fixnum_value(4) };
    call(M, "one on a String", probe, "one", 2, s2);
    mrb_value a3[] = { eval(M, "[1, 2, 3]"), mrb_fixnum_value(1), mrb_fixnum_value(7) };
    call(M, "two", probe, "two", 3, a3);
    mrb_value s3[] = { eval(M, "'ab'"), mrb_fixnum_value(1), eval(M, "'x'") };
    call(M, "two on a String", probe, "two", 3, s3);
    call(M, "blk", probe, "blk", 1, a1);
    mrb_value a4[] = { eval(M, "[0]") };
    call(M, "three", probe, "three", 1, a4);
    mrb_value p1[] = { eval(M, "[65, 66]") };
    call(M, "peek public", probe, "peek", 1, p1);
    eval(M, "class Array; private :pack; end");
    call(M, "peek private", probe, "peek", 1, p1);
    eval(M, "class String; def size(x) = x; end");
    call(M, "zero after arity change", probe, "zero", 1, s1);
    return 0;
  }
CPP

Dir.mktmpdir('owner-call-arity') do |dir|
  ENV['BC2CPP_OWNER_CALL_ARITY'] = '1'
  code, err = runtime.generate(ARITY_SOURCE, dir, only_owners: ARITY_OWNERS)
  forms = code.scan(/\b(bc2cpp_owner_call(?:[0-2]|_b0)?)\(M, /).flatten.tally
  check.call("each entry is used (#{forms.inspect})",
             %w[bc2cpp_owner_call0 bc2cpp_owner_call1 bc2cpp_owner_call2 bc2cpp_owner_call_b0].all? { |f| forms[f].to_i.positive? })
  check.call('three arguments stay general', code.match?(/bc2cpp_owner_call\(M, [^\n]*, mrb_nil_value\(\), 3, /))
  check.call('the owner-call comments stay', code.scan(%r{/\* CLOSED_WORLD owner-call: [^*]+ \*/}).size >= forms.values.sum)
  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, ARITY_OWNERS, ARITY_HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    compiled = plain.call(sections['compiled'])
    interpreted = plain.call(sections['interpreted'])
    check.call('built and ran', built)
    check.call('compiled matches interpreted', !compiled.empty? && compiled == interpreted)
    check.call('private raises', compiled.any? { |l| l.include?('peek private => raised NoMethodError') })
    check.call('a wrong argument count raises', compiled.any? { |l| l.include?('zero after arity change => raised ArgumentError') })
    warn output unless failures.empty?
  else
    puts '  SKIP run: no full-core mruby build'
  end
ensure
  ENV.delete('BC2CPP_OWNER_CALL_ARITY')
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp owner set share check: PASS'
