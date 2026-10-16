#!/usr/bin/env ruby
# frozen_string_literal: true

# Check SELF_NEW_LEAF (docs/adr/0468): `new` on `self` in a singleton method of class C, and `self.class.new` in an
# instance method of C, construct directly. The receiver is one of the classes the method can be called on: C and its
# subclasses, which the closed world lists. A leaf C makes the receiver exactly C (no guard); a C with known
# subclasses gets one exact-class arm per class, each a direct allocation plus the initialize that class resolves to,
# and a closed-world violation for any other receiver; an unknown subclass (Class.new(C)) keeps the dispatch.
#
#   1. generated code: the leaf's sites are unguarded direct constructions, the inherited singleton method and
#      `self.class.new` of the base have one arm per class of {base, kid}, and Class.new keeps the by-name send;
#   2. run (full-core mruby), interpreted against compiled: every site builds an object of the receiver's class with
#      the right initialize, including the kid that inherits `make` and the kid that overrides initialize.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/self_new_leaf_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class SnLeaf
    def initialize(a); @a = a; end
    def a; @a; end
    def self.make(a); new(a); end
    def self.make_self(a); self.new(a); end
    def again; self.class.new(@a + 1); end
  end
  class SnBase
    def initialize(a); @a = a; end
    def a; @a; end
    def self.make(a); new(a); end
    def again; self.class.new(@a + 1); end
  end
  class SnKid < SnBase
    def initialize(a); @a = a * 10; end
  end
  class SnOpen
    def initialize(a); @a = a; end
    def a; @a; end
    def self.make(a); new(a); end
  end
  SN_ANON = Class.new(SnOpen)
RUBY
OWNERS = %w[SnLeaf SnLeaf.singleton SnBase SnBase.singleton SnKid SnOpen SnOpen.singleton].freeze

body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('self-new-leaf') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'self_new_leaf.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  %w[SnLeaf_singleton_make SnLeaf_singleton_make_self SnLeaf_again].each do |fn|
    b = body.call(code, fn)
    check.call("#{fn}: leaf receiver, direct construction with no guard",
               b.include?('SELF_NEW_LEAF') && b.include?('bc2cpp_direct_alloc(M, mrb_class_ptr(') &&
                 b.include?('SnLeaf_initialize_impl(M, ') && !b[/SELF_NEW_LEAF.*/m].include?('if (') && !b.include?('bc2cpp_send('))
  end
  %w[SnBase_singleton_make SnBase_again].each do |fn|
    b = body.call(code, fn)
    check.call("#{fn}: one exact-class arm per class it can be called on, else a violation",
               b.include?('SELF_NEW_LEAF') && b.include?('SnBase_initialize_impl(M, ') && b.include?('SnKid_initialize_impl(M, ') &&
                 b.include?('bc2cpp_guard_violation(') && !b.include?('bc2cpp_send('))
  end
  open_make = body.call(code, 'SnOpen_singleton_make')
  check.call('Class.new(C) makes C non-leaf: only exactly C constructs directly, any other class dispatches',
             !open_make.match?(/\A(?:(?!if \().)*bc2cpp_direct_alloc/m) && open_make.include?('bc2cpp_send(') &&
               !open_make.include?('bc2cpp_guard_violation('))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
      static int scenario(mrb_state* M) {
        const char* rows[] = {
          "o = SnLeaf.make(1); [o.class, o.a]",
          "o = SnLeaf.make_self(2); [o.class, o.a]",
          "o = SnLeaf.make(3).again; [o.class, o.a]",
          "o = SnBase.make(1); [o.class, o.a]",
          "o = SnKid.make(1); [o.class, o.a]",
          "o = SnBase.make(1).again; [o.class, o.a]",
          "o = SnKid.make(1).again; [o.class, o.a]",
          "o = SnOpen.make(1); [o.class, o.a]",
          "o = SN_ANON.make(2); [o.class == SN_ANON, o.a]",
        };
        for (const char* src : rows) {
          mrb_value v = eval(M, src);
          if (M->exc) { show_exc(M, src); continue; }
          show(M, src, v);
        }
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output)
      check.call('built and ran', built)
      check.call('runtime parity, interpreted against compiled', !sections['compiled'].to_a.empty? &&
                                                                  sections['compiled'] == sections['interpreted'])
      check.call('the kid that inherits make builds a kid', sections['compiled'].to_a.any? { |l| l.include?('SnKid.make(1); [o.class, o.a] => [SnKid, 10]') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp self new leaf check: PASS'
