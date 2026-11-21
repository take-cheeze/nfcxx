#!/usr/bin/env ruby
# frozen_string_literal: true

# KEYWORD_SPLAT_DYNAMIC_SEND (keyword_dynamic_send): a blockless send with a packed shape that no static callee
# resolves -- `m(a, **h)` (`n=1|nk=*`), `m(*list, k: v)` (`n=*|nk=1`), `m(*list, **h)` -- is the by-name send OP_SEND
# makes: the keyword Hash (checked by mrb_ensure_hash_type, as OP_SEND does) or the packed pairs go as keywords and the
# Array's items as the positionals (bc2cpp_send_kw, mrb_funcall_send). The fixture sends to a name two classes define
# (so no static callee), to method_missing, to a C method (Hash#merge, Array#push), with an empty keyword Hash, and to
# a private method through an explicit receiver (NoMethodError). The behaviour part needs BC2CPP_MRUBY_FULL, or rake and
# a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_splat_dynamic_send_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class KsdA
    def pick(x = 0, *rest, k: 1, **more) = [:a, x, rest, k, more]
  end
  class KsdB
    def pick(*all, **kw) = [:b, all, kw]

    def method_missing(name, *args, **kw) = [:mm, name, args, kw]

    def respond_to_missing?(_name, _priv = false) = true

    private

    def secret(**kw) = kw
  end
  class KsdUser
    def run_kwsplat(o, h) = o.pick(5, **h)
    def run_kwsplat_only(o, h) = o.pick(**h)
    def run_splat_kw(o, list) = o.pick(*list, k: 9)
    def run_both(o, list, h) = o.pick(*list, **h)
    def run_mm(o, h) = o.anything(1, **h)
    def run_cfunc(h) = [{ z: 0 }.merge(**h), [].push(*[1, 2], **h)]
    def run_private(o, h)
      o.secret(**h)
    rescue NoMethodError => e
      e.message
    end
    def run_all(_x)
      a = KsdA.new
      b = KsdB.new
      h = { k: 3, j: 4 }
      e = {}
      [run_kwsplat(a, h), run_kwsplat(b, h), run_kwsplat(a, e), run_kwsplat_only(a, h), run_kwsplat_only(b, e),
       run_splat_kw(a, [1, 2]), run_splat_kw(b, []), run_both(a, [7], h), run_both(b, [7, 8], e), run_mm(b, h),
       run_cfunc(h), run_private(b, h)]
    end
  end
RUBY

OWNERS = %w[KsdA KsdB KsdUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-keyword-splat-dynamic-send') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('methods sending packed keywords by name compile',
              %w[run_kwsplat run_kwsplat_only run_splat_kw run_both run_mm run_cfunc run_private].all? do |m|
                compiled?(code, "KsdUser_#{m}_impl")
              end)
  suite.check('the keyword Hash is checked as OP_SEND checks it', code.include?('mrb_ensure_hash_type(M, '))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP keyword splat dynamic send behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "KsdUser")), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value nil = mrb_nil_value();
        call(M, "run_all", u, "run_all", 1, &nil);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter passes the keywords as keywords',
                interpreted.any? { |l| l.start_with?('run_all => [[:a, 5, [], 3, {j: 4}], [:b, [5], {k: 3, j: 4}]') })
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
