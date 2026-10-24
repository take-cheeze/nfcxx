#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BC2CPP_ENTRY: the host-callable entry header bc2cpp writes as <OUT_SYMBOL>_entry.h
# (tools/bc2cpp/codegen_entry_header.rb, docs/bc2cpp-entry-points.md).
#
#   generated header (needs a host mrbc)
#     - a clean public method declared as an entry point is the direct form (BC2CPP_ENTRY_<Owner>_<name> 1), with
#       or without arguments;
#     - one that takes a rest argument or reads its block stays by name (0), and an undeclared one is absent;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the direct form makes no dynamic dispatch and returns what mrb_funcall returns;
#     - a raise inside leaves the exception in M->exc and returns it, as mrb_funcall does, and does not escape;
#       inside a protected region it propagates to that region instead;
#     - a subclass receiver and a receiver with a singleton class take the by-name call;
#   include/bc2cpp_entry.hxx
#     - has a by-name fallback for every entry in ENTRY_POINTS.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/entry_header_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/codegen_entry_header'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

puts '-- include/bc2cpp_entry.hxx'
fallback = File.read(File.join(Bc2cppFixtureRuntime::ROOT, 'include/bc2cpp_entry.hxx'))
EntryHeader.entry_points(nil).each do |e|
  ident = "#{e.owner.gsub('::', '__')}_#{e.name}"
  check.call("a by-name fallback for #{e.owner}##{e.name}",
             fallback.include?("#ifndef BC2CPP_ENTRY_#{ident}\n") &&
               fallback.include?("bc2cpp_entry_#{ident}(") &&
               fallback.include?("mrb_funcall(M, self, \"#{e.name}\", #{e.argc}"))
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-header and behavioural checks need it'
  exit(failures.empty? ? 0 : 1)
end

SRC = <<~'RUBY'
  class EntryGame
    def initialize
      @n = 0
    end

    def tick
      @n += 1
    end

    def add(x)
      @n += x
    end

    def count
      @n
    end

    def boom
      raise ArgumentError, 'entry boom'
    end

    def gather(*xs)
      xs.size
    end

    def each_twice
      yield
      yield
    end
  end

  class EntrySub < EntryGame
    def tick
      @n += 100
    end
  end
RUBY

OWNERS = %w[EntryGame EntrySub].freeze
ENV['BC2CPP_ENTRY_POINTS'] = %w[EntryGame#tick/0 EntryGame#add/1 EntryGame#count/0 EntryGame#boom/0
                                EntryGame#gather/0 EntryGame#each_twice/0].join(' ')

Dir.mktmpdir('bc2cpp-entry-header') do |dir|
  puts '-- generated header'
  _, err = Bc2cppFixtureRuntime.generate(SRC, dir, only_owners: OWNERS)
  path = File.join(dir, 'fixture_entry.h')
  header = File.exist?(path) ? File.read(path) : ''
  check.call('bc2cpp writes fixture_entry.h beside the generated code', !header.empty?)
  %w[tick add count boom].each do |name|
    check.call("EntryGame##{name} is the direct form", header.include?("#define BC2CPP_ENTRY_EntryGame_#{name} 1\n"))
  end
  check.call('EntryGame#gather (rest argument) stays by name', header.include?("#define BC2CPP_ENTRY_EntryGame_gather 0\n"))
  check.call('EntryGame#each_twice (yields its block) stays by name',
             header.include?("#define BC2CPP_ENTRY_EntryGame_each_twice 0\n"))
  check.call('an undeclared method gets no entry', !header.include?('bc2cpp_entry_EntrySub_tick'))

  build = Bc2cppFixtureRuntime.full_or_build
  unless build
    puts '  SKIP: no full-core libmruby (BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR); behaviour unchecked'
    next
  end

  puts '-- behaviour'
  body = <<~CPP
    #include "fixture_entry.h"
    static long fix(mrb_value v) { return mrb_integer_p(v) ? (long)mrb_integer(v) : -1; }
    static mrb_value boom_in_region(mrb_state* M, void* ud) {
      return bc2cpp_entry_EntryGame_boom(M, *static_cast<mrb_value*>(ud));
    }
    static int scenario(mrb_state* M) {
      if (!compiled) return 0;
      mrb_value g = mrb_obj_new(M, mrb_class_get(M, "EntryGame"), 0, nullptr);
      mrb_gc_register(M, g);
      dispatches = 0;
      bc2cpp_entry_EntryGame_tick(M, g);
      long added = fix(bc2cpp_entry_EntryGame_add(M, g, mrb_fixnum_value(5)));
      long counted = fix(bc2cpp_entry_EntryGame_count(M, g));
      int made = dispatches;
      std::printf("direct add=%ld count=%ld dispatches=%d\\n", added, counted, made);

      dispatches = 0;
      mrb_value e = bc2cpp_entry_EntryGame_boom(M, g);
      made = dispatches;
      bool exc_set = M->exc != nullptr && M->exc == mrb_obj_ptr(e);
      std::printf("boom exc=%s same=%d dispatches=%d\\n", M->exc ? mrb_obj_classname(M, mrb_obj_value(M->exc)) : "none",
                  exc_set, made);
      M->exc = nullptr;
      mrb_value by_name = mrb_funcall(M, g, "boom", 0);
      std::printf("funcall boom exc=%s same=%d\\n", M->exc ? mrb_obj_classname(M, mrb_obj_value(M->exc)) : "none",
                  M->exc != nullptr && M->exc == mrb_obj_ptr(by_name));
      M->exc = nullptr;

      mrb_bool error = FALSE;
      mrb_value caught = mrb_protect_error(M, boom_in_region, &g, &error);
      std::printf("region error=%d class=%s exc_after=%d\\n", error, mrb_obj_classname(M, caught), M->exc != nullptr);

      mrb_value s = mrb_obj_new(M, mrb_class_get(M, "EntrySub"), 0, nullptr);
      dispatches = 0;
      long sub_tick = fix(bc2cpp_entry_EntryGame_tick(M, s));
      made = dispatches;
      std::printf("sub tick=%ld dispatches=%d\\n", sub_tick, made);

      mrb_value t = mrb_obj_new(M, mrb_class_get(M, "EntryGame"), 0, nullptr);
      mrb_define_singleton_method(M, mrb_obj_ptr(t), "tick",
                                  [](mrb_state*, mrb_value) -> mrb_value { return mrb_fixnum_value(1000); },
                                  MRB_ARGS_NONE());
      dispatches = 0;
      long single_tick = fix(bc2cpp_entry_EntryGame_tick(M, t));
      made = dispatches;
      std::printf("singleton tick=%ld dispatches=%d\\n", single_tick, made);

      dispatches = 0;
      long gathered = fix(bc2cpp_entry_EntryGame_gather(M, g));
      made = dispatches;
      std::printf("by-name gather=%ld dispatches=%d\\n", gathered, made);
      std::printf("end\\n");
      return 0;
    }
  CPP
  built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true, vms: [true])
  check.call('the fixture builds and runs', built)
  lines = Bc2cppFixtureRuntime.sections(output)['compiled'] || []
  check.call('the direct form returns the same values and makes no dynamic dispatch',
             lines.include?('direct add=6 count=6 dispatches=0'))
  check.call('a raise leaves the exception in M->exc and returns it, as mrb_funcall does',
             lines.include?('boom exc=ArgumentError same=1 dispatches=0') &&
               lines.include?('funcall boom exc=ArgumentError same=1'))
  check.call('inside a protected region the raise reaches that region',
             lines.include?('region error=1 class=ArgumentError exc_after=0'))
  check.call('a subclass receiver runs its own method, by name', lines.include?('sub tick=100 dispatches=1'))
  check.call('a receiver with a singleton method runs it, by name', lines.include?('singleton tick=1000 dispatches=1'))
  check.call('a by-name entry dispatches', lines.include?('by-name gather=0 dispatches=1'))
  puts output.lines.last(30).join unless built && lines.last == 'end'
end

if failures.empty?
  puts 'bc2cpp entry header check: PASS'
else
  warn "bc2cpp entry header check: #{failures.size} failure(s)"
  exit 1
end
