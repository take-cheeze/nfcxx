#!/usr/bin/env ruby
# frozen_string_literal: true

# KEYWORD_DYNAMIC_SEND (codegen_keyword_send.rb, keyword_dynamic_send): a blockless `recv.m(a, k: v)` whose callee no
# static proof names compiles to the by-name send OP_SEND makes, the literal pairs packed into one Hash and passed as
# keywords (bc2cpp_send_kw -> mrb_funcall_send). The check reads the generated sites and, with a full-core libmruby,
# runs every case interpreted and compiled: two definers of the name, a Class#new forwarding its keywords, a
# method_missing receiving them, a keywordless callee taking them as a trailing Hash, missing/unknown keyword and
# arity errors, an attr_reader given keywords, and OP_SEND's private/protected checks for an explicit receiver.
# Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_dynamic_send_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class KdA
    attr_reader :v
    def initialize(x, k: 1)
      @v = [x, k]
    end
    def go(a, b: 2, c: 3)
      [:a, a, b, c]
    end
    def need(a, r:)
      [a, r]
    end
    protected def prot(a, z: 0)
      [:prot, a, z]
    end
    def call_prot(o)
      o.prot(1, z: 9)
    end
  end

  class KdB
    def go(a, b: 5, c: 7)
      [:b, a, b, c]
    end
    private def hidden(a, z: 1)
      a + z
    end
  end

  class KdHash
    def go(a, h)
      [:hash, a, h]
    end
  end

  class KdGhost
    def method_missing(name, *args, **kw)
      [name, args, kw]
    end
    def respond_to_missing?(name, priv = false) = true
  end

  # Not an owner: its reader stays the VM's own attr_reader (a NOARG cfunc proc). A compiled owner's reader is
  # registered by the fixture with MRB_ARGS_ANY, which would hide the argument check.
  class KdR
    attr_reader :w
  end

  class KdDrive
    def go(o, v)
      o.go(v, b: 10, c: 20)
    end
    def go_c(o, v)
      o.go(v, c: 1)
    end
    def build(cls, v)
      cls.new(v, k: 3).v
    end
    def need(o)
      o.need(1, r: 2)
    end
    def need_unknown(o)
      o.need(1, r: 2, q: 3)
    end
    def need_arity(o)
      o.need(1, 2, r: 3)
    end
    def hidden(o)
      o.hidden(1, z: 2)
    end
    def prot(o)
      o.prot(1, z: 2)
    end
    def reader(o)
      o.w(k: 1)
    end
    def ghost(o)
      o.anything(1, 2, k: 3, j: 4)
    end
  end
RUBY

OWNERS = %w[KdA KdB KdHash KdGhost KdDrive].freeze

Dir.mktmpdir('bc2cpp-keyword-dynamic-send') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  drive = code[/^mrb_value KdDrive_go_impl\(mrb_state\* M.*?^\}/m].to_s
  suite.check('a keyword send with two definers compiles to the dynamic keyword send',
              drive.include?('KEYWORD_DYNAMIC_SEND :go (n=1|nk=2)') &&
              drive.include?('mrb_value bc2cpp_kwd = mrb_hash_new_capa(M, 2);') &&
              drive.match?(/= bc2cpp_send_kw\(M, r\d+, [^;]*, 1, bc2cpp_kwd_argv, bc2cpp_kwd, true, self\);/))
  suite.check('no KdDrive method stays interpreted for its keyword send',
              err.lines.none? { |l| l.include?('KdDrive#') && l.include?('keyword argument list') })
  suite.check('every KdDrive method is a compiled entry point',
              %w[go go_c build need need_unknown need_arity hidden prot reader ghost].all? { |m| err.include?("(KdDrive##{m}, ") })

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP keyword dynamic send behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value kd_new(mrb_state* M, const char* cls, int argc = 0, const mrb_value* argv = nullptr) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), argc, argv);
      }
      static int scenario(mrb_state* M) {
        mrb_value one = mrb_fixnum_value(1);
        mrb_value d = kd_new(M, "KdDrive");
        mrb_value a = kd_new(M, "KdA", 1, &one);
        mrb_value b = kd_new(M, "KdB");
        mrb_value h = kd_new(M, "KdHash");
        mrb_value g = kd_new(M, "KdGhost");
        mrb_value a_v[] = {a, mrb_fixnum_value(2)};
        mrb_value b_v[] = {b, mrb_fixnum_value(2)};
        mrb_value h_v[] = {h, mrb_fixnum_value(2)};
        call(M, "go_a", d, "go", 2, a_v);
        call(M, "go_b", d, "go", 2, b_v);
        call(M, "go_hash", d, "go", 2, h_v);
        call(M, "go_c_a", d, "go_c", 2, a_v);
        call(M, "go_c_b", d, "go_c", 2, b_v);
        mrb_value cls_v[] = {mrb_obj_value(mrb_class_get(M, "KdA")), mrb_fixnum_value(4)};
        call(M, "build", d, "build", 2, cls_v);
        call(M, "need", d, "need", 1, &a);
        call(M, "need_unknown", d, "need_unknown", 1, &a);
        call(M, "need_arity", d, "need_arity", 1, &a);
        call(M, "hidden", d, "hidden", 1, &b);
        call(M, "prot_outside", d, "prot", 1, &a);
        call(M, "prot_inside", a, "call_prot", 1, &a);
        mrb_value r = kd_new(M, "KdR");
        call(M, "reader", d, "reader", 1, &r);
        call(M, "ghost", d, "ghost", 1, &g);
        mrb_value g_v[] = {g, mrb_fixnum_value(5)};
        call(M, "go_ghost", d, "go", 2, g_v);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every call ran', interpreted.size == 15)
    expected = [
      'go_a => [:a, 2, 10, 20]', 'go_b => [:b, 2, 10, 20]', 'go_hash => [:hash, 2, {b: 10, c: 20}]',
      'go_c_a => [:a, 2, 2, 1]', 'go_c_b => [:b, 2, 5, 1]', 'build => [4, 3]', 'need => [1, 2]',
      'need_unknown => raised ArgumentError', 'need_arity => raised ArgumentError', 'hidden => raised NoMethodError',
      'prot_outside => raised NoMethodError', 'prot_inside => [:prot, 1, 9]', 'reader => raised ArgumentError',
      'ghost => [:anything, [1, 2], {k: 3, j: 4}]', 'go_ghost => [:go, [5], {b: 10, c: 20}]'
    ]
    suite.check('the interpreter gives the expected answers', interpreted == expected)
    puts "  interpreted: #{interpreted.inspect}" unless interpreted == expected
    suite.check('compiled matches interpreted', compiled == interpreted)
    puts "  compiled: #{compiled.inspect}" unless compiled == interpreted
  end
end

suite.finish!
