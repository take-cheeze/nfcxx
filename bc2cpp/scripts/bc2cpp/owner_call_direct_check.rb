#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_CALL_DIRECT (tools/bc2cpp/owner_call_direct.rb): an owner call whose listed engine owners its gem's entries
# complete carries those entries, and finds them without the owners' method-table entries.
#
#   generated code:
#     - `push`, which Array also answers, is a chain of exact-class arms over the engine owners with an owner call
#       as its else (STATIC_OWNER_ARMS); the arms compare mrb_class, so an instance with a singleton class takes the
#       else too, and the call carries both engine owners' entries (Game::OcdA, also inherited by any class made at
#       run time, and Game::OcdC);
#     - an owner call listing an engine owner with no entry here (Game::OcdD, not compiled) keeps the plain owner
#       set;
#     - the closed-list proof (OWNER_CALL_GUARDED) counts the completed call as no lookup of `push`, and does not
#       with BC2CPP_OWNER_CALL_DIRECT=0;
#   run on a full-core mruby, compiled against interpreted:
#     - with Game::OcdA#push removed from the table (a left-out entry), an instance of a class made at run time
#       under Game::OcdA still answers;
#     - with an aborting stub registered there instead (a verify build), the stub never runs;
#     - with BC2CPP_OWNER_CALL_DIRECT=0 and the entry removed, that instance raises (the check sees the gap).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/owner_call_direct_check.rb
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('owner_call_direct_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  module Game
    class OcdA
      def push(x) = x + 1
      def pick = :a
    end

    class OcdB < OcdA
    end

    class OcdC
      def push(x) = x * 2
    end

    class OcdD
      def pick = :d
    end

    class OcdUser
      def go(o, x) = o.push(x)
      def choose(o) = o.pick
    end
  end
RUBY
OWNERS = %w[Game::OcdA Game::OcdB Game::OcdC Game::OcdUser].freeze

HARNESS = <<~'CPP'
  #include <cstdlib>
  #include <cstring>
  static mrb_value ocd_stub(mrb_state* M, mrb_value self) {
    std::printf("OCD stub reached\n");
    std::fflush(stdout);
    abort();
    return self;
  }
  static mrb_value ocd_new(mrb_state* M, const char* name) {
    struct RClass* game = mrb_module_get(M, "Game");
    return mrb_obj_new(M, mrb_class_get_under(M, game, name), 0, nullptr);
  }
  static int scenario(mrb_state* M) {
    const char* mode = getenv("OCD_MODE");
    struct RClass* a = mrb_class_get_under(M, mrb_module_get(M, "Game"), "OcdA");
    if (compiled && mode && strcmp(mode, "removed") == 0) mrb_remove_method(M, a, mrb_intern_lit(M, "push"));
    if (compiled && mode && strcmp(mode, "stub") == 0) mrb_define_method(M, a, "push", ocd_stub, MRB_ARGS_ANY());
    mrb_value user = ocd_new(M, "OcdUser");
    const char* names[] = { "OcdA", "OcdB", "OcdC" };
    for (const char* n : names) {
      mrb_value args[] = { ocd_new(M, n), mrb_fixnum_value(10) };
      call(M, n, user, "go", 2, args);
    }
    mrb_value made[] = { mrb_load_string(M, "Class.new(Game::OcdA).new"), mrb_fixnum_value(10) };
    call(M, "made", user, "go", 2, made);
    return 0;
  }
CPP

def go_site(code, name)
  code.lines.find { |l| l.include?("CLOSED_WORLD owner-call: #{name} */") }.to_s
end

Dir.mktmpdir('bc2cpp-owner-call-direct') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  push = go_site(code, 'push')
  suite.check('the else of exact-class arms carries both engine owners\' entries',
              push.include?('BC2CPP_OWNERS_D(BC2CPP_OWNER_DIRECT("Game::OcdA", Game__OcdA_push, ') &&
              push.include?('BC2CPP_OWNER_DIRECT("Game::OcdC", Game__OcdC_push, ') && push.include?('"Array"'))
  suite.check('an engine owner with no entry here keeps the plain owner set',
              go_site(code, 'pick').include?('BC2CPP_OWNERS("Game::OcdA", "Game::OcdD")'))
  # As the text scan finds `< OcdA`.
  subclassed = %w[Game::OcdA OcdA]
  suite.check('the proof counts the completed call as no lookup',
              StaticDispatchRegistrations.lookup_free_names(code, subclassed).include?('push'))
  begin
    ENV['BC2CPP_OWNER_CALL_DIRECT'] = '0'
    off_dir = FileUtils.mkdir_p(File.join(dir, 'off')).first
    off, off_err = Bc2cppFixtureRuntime.generate(SOURCE, off_dir, core: true, only_owners: OWNERS)
  ensure
    ENV.delete('BC2CPP_OWNER_CALL_DIRECT')
  end
  suite.check('BC2CPP_OWNER_CALL_DIRECT=0: no entries, and the call is a lookup',
              !off.include?('BC2CPP_OWNERS_D(BC2CPP') && !StaticDispatchRegistrations.lookup_free_names(off, subclassed).include?('push'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP owner call direct behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    envs = %w[removed stub].map { |m| { 'OCD_MODE' => m } }
    built, runs = Bc2cppFixtureRuntime.run(dir, err, OWNERS, HARNESS, build: build, full: true, envs: envs)
    suite.check('fixture builds', built)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    (runs || []).zip(%w[removed stub]).each do |(output, ok), mode|
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = plain.call(sections['interpreted'])
      compiled = plain.call(sections['compiled'])
      suite.check("#{mode}: every call answered", ok && interpreted.size == 4 && interpreted.include?('made => 11'))
      suite.check("#{mode}: compiled matches interpreted", compiled == interpreted)
    end
    built_off, runs_off = Bc2cppFixtureRuntime.run(off_dir, off_err, OWNERS, HARNESS, build: build, full: true,
                                                   envs: [{ 'OCD_MODE' => 'removed' }])
    off_compiled = built_off && plain.call(Bc2cppFixtureRuntime.sections(runs_off[0][0])['compiled'])
    suite.check('BC2CPP_OWNER_CALL_DIRECT=0 with the entry removed: the made instance raises',
                off_compiled && off_compiled.any? { |l| l.start_with?('made => raised') })
  end
end

suite.finish!
