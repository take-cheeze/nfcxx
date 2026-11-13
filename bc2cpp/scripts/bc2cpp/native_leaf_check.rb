#!/usr/bin/env ruby
# frozen_string_literal: true

# Check NATIVE_LEAF and the written superclass path (tools/bc2cpp/closed_world.rb: bounded_subclasses,
# superclass_candidates) on a ClosedWorld over fixture declarations and native sources:
#   1. a declared class a native source defines (its origin) and spells elsewhere in that file is a leaf;
#   2. a native class defined with it as the superclass (a literal lookup, a variable holding one, or an unresolved
#      expression) or a class_new of it makes its subclasses unknown;
#   3. `class Battle < A::Scene::Battle` is a subclass of A::Scene::Battle only, not of every Battle; a rebound
#      segment of the path keeps the last-segment match.
#
# Usage: ruby scripts/bc2cpp/native_leaf_check.rb

require 'tmpdir'
require 'set'
require_relative '../../tools/bc2cpp/closed_world'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ORIGIN = <<~CPP
  #include <mruby.h>
  struct Bitmap { int w; };
  static mrb_value bitmap_width(mrb_state* M, mrb_value self) { return mrb_nil_value(); }
  static mrb_value check_live(mrb_state* M, mrb_value self) {
    mrb_raise(M, mrb_class_get_under(M, mrb_module_get(M, "Gfx"), "Bitmap"), "disposed Bitmap");
    return self;
  }
  void gfx_init(mrb_state* M) {
    RClass* m = mrb_define_module(M, "Gfx");
    RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
    mrb_define_method(M, bmp, "width", bitmap_width, MRB_ARGS_NONE());
  }
CPP

SUBCLASSES = {
  'a literal superclass lookup' => <<~CPP,
    void sub_init(mrb_state* M) {
      RClass* m = mrb_module_get(M, "Gfx");
      mrb_define_class_under(M, m, "Sub", mrb_class_get_under(M, m, "Bitmap"));
    }
  CPP
  'a variable holding the superclass' => <<~CPP,
    void sub_init(mrb_state* M) {
      RClass* m = mrb_module_get(M, "Gfx");
      RClass* base = mrb_class_get_under(M, m, "Bitmap");
      mrb_define_class_under(M, m, "Sub", base);
    }
  CPP
  'an unresolved superclass expression' => <<~CPP,
    void sub_init(mrb_state* M, RClass* (*pick)(mrb_state*)) {
      mrb_define_class(M, "Sub", pick(M));
      (void)"Gfx"; (void)"Bitmap";
    }
  CPP
  'a class_new of it' => <<~CPP
    void sub_init(mrb_state* M) {
      mrb_class_new(M, mrb_class_get_under(M, mrb_module_get(M, "Gfx"), "Bitmap"));
    }
  CPP
}.freeze

DECLS = {
  'Gfx::Bitmap' => [{ super: :none, outer_nil: true, outer_qualified: false }],
  'A::Scene::Battle' => [{ super: :none, outer_nil: true, outer_qualified: false }],
  'B::Scene::Battle' => [{ super: 'A::Scene::Battle', outer_nil: true, outer_qualified: false }],
  'Game::Battle' => [{ super: :none, outer_nil: true, outer_qualified: false }]
}.freeze

world = lambda do |natives, decls: DECLS|
  ClosedWorld.new(ireps: {}, registry: {}, class_decls: decls, walked: {}, native_paths: natives, ruby_paths: [],
                  module_names: Set['Gfx', 'A', 'A::Scene', 'B', 'B::Scene', 'Game', 'C'])
end

Dir.mktmpdir('native-leaf') do |dir|
  origin = File.join(dir, 'gfx.cxx')
  File.write(origin, ORIGIN)

  puts '-- 1. a natively defined declared class'
  w = world.call([origin])
  check.call('Gfx::Bitmap is an exact class (its native definition is its origin)', w.exact_class?('Gfx::Bitmap'))
  check.call('Gfx::Bitmap is a leaf although its source spells the name', w.known_subclasses('Gfx::Bitmap') == ['Gfx::Bitmap'])

  puts '-- 2. a native subclass'
  SUBCLASSES.each do |what, code|
    sub = File.join(dir, 'sub.cxx')
    File.write(sub, code)
    w = world.call([origin, sub])
    check.call("#{what}: Gfx::Bitmap's subclasses are unknown", w.known_subclasses('Gfx::Bitmap').nil?)
  end

  puts '-- 3. a written superclass path'
  w = world.call([origin])
  check.call('A::Scene::Battle has the subclass that names its path', w.known_subclasses('A::Scene::Battle') ==
             ['A::Scene::Battle', 'B::Scene::Battle'])
  check.call('Game::Battle is a leaf (B::Scene::Battle names another Battle)', w.known_subclasses('Game::Battle') == ['Game::Battle'])
  bare = world.call([origin], decls: DECLS.merge('C::Battle' => [{ super: 'Battle', outer_nil: true, outer_qualified: false }]))
  check.call('a bare `< Battle` may be any Battle', bare.send(:descendants, 'Game::Battle').include?('C::Battle'))
  rw = world.call([origin])
  rw.instance_variable_get(:@rebound) << 'Scene'
  rw.instance_variable_set(:@desc_memo, {})
  rw.send(:build_hierarchy)
  check.call('a rebound path segment keeps the last-segment match', rw.send(:descendants, 'Game::Battle').include?('B::Scene::Battle'))
end

if failures.empty?
  puts 'PASS'
else
  puts "FAIL (#{failures.size})"
  exit 1
end
