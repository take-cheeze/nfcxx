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
#   constructor entries (Owner.new/argc, BC2CPP_ENTRY_NEW)
#     - a class whose initialize is a clean plain forwarder gets the direct form; a rest-argument initialize does not;
#     - the direct form allocates an instance of the class and runs the compiled initialize with no dynamic dispatch;
#     - a raising initialize leaves the exception in M->exc and returns the new object, as mrb_obj_new does;
#     - a different argument count takes mrb_obj_new (and its ArgumentError), as does a by-name constructor entry;
#   include/bc2cpp_entry.hxx
#     - has a by-name fallback for every entry in ENTRY_POINTS and HOST_ONLY_ENTRY_POINTS.
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
(EntryHeader.entry_points(nil) + EntryHeader.parse(EntryHeader::HOST_ONLY_ENTRY_POINTS)).each do |e|
  ident = "#{e.owner.gsub('::', '__')}_#{e.name}"
  call = if e.ctor
           "mrb_obj_new(M, mrb_class_get(M, \"#{e.owner}\"), argc, argv)"
         else
           "mrb_funcall(M, self, \"#{e.name}\", #{e.argc}"
         end
  check.call("a by-name fallback for #{e.owner}#{e.ctor ? '.' : '#'}#{e.name}",
             fallback.include?("#ifndef BC2CPP_ENTRY_#{ident}\n") &&
               fallback.include?("bc2cpp_entry_#{ident}(") && fallback.include?(call))
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

  class EntryMade
    def initialize(start)
      @n = start + 1
    end

    def count
      @n
    end
  end

  class EntryBoomInit
    def initialize(x)
      raise ArgumentError, "init #{x}"
    end
  end

  class EntryRestInit
    def initialize(*xs)
      @n = xs.size
    end

    def size
      @n
    end
  end
RUBY

OWNERS = %w[EntryGame EntrySub EntryMade EntryBoomInit EntryRestInit].freeze
ENV['BC2CPP_ENTRY_POINTS'] = %w[EntryGame#tick/0 EntryGame#add/1 EntryGame#count/0 EntryGame#boom/0
                                EntryGame#gather/0 EntryGame#each_twice/0 EntryGame.new/0 EntryMade.new/1
                                EntryBoomInit.new/1 EntryRestInit.new/1].join(' ')

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
  %w[EntryGame EntryMade EntryBoomInit].each do |owner|
    check.call("#{owner}.new is the direct form", header.include?("#define BC2CPP_ENTRY_#{owner}_new 1\n"))
  end
  check.call('EntryRestInit.new (rest-argument initialize) stays mrb_obj_new',
             header.include?("#define BC2CPP_ENTRY_EntryRestInit_new 0\n"))

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

      mrb_value seven = mrb_fixnum_value(7);
      dispatches = 0;
      mrb_value em = bc2cpp_entry_EntryMade_new(M, 1, &seven);
      made = dispatches;
      std::printf("new class=%s count=%ld dispatches=%d exc=%d\\n", mrb_obj_classname(M, em),
                  fix(mrb_funcall(M, em, "count", 0)), made,
                  M->exc != nullptr);
      mrb_value eg = bc2cpp_entry_EntryGame_new(M, 0, nullptr);
      std::printf("new0 count=%ld\\n", fix(bc2cpp_entry_EntryGame_count(M, eg)));

      dispatches = 0;
      mrb_value eb = bc2cpp_entry_EntryBoomInit_new(M, 1, &seven);
      made = dispatches;
      std::printf("new boom class=%s exc=%s dispatches=%d\\n", mrb_obj_classname(M, eb),
                  M->exc ? mrb_obj_classname(M, mrb_obj_value(M->exc)) : "none", made);
      M->exc = nullptr;
      mrb_value ob = mrb_obj_new(M, mrb_class_get(M, "EntryBoomInit"), 1, &seven);
      std::printf("obj_new boom class=%s exc=%s\\n", mrb_obj_classname(M, ob),
                  M->exc ? mrb_obj_classname(M, mrb_obj_value(M->exc)) : "none");
      M->exc = nullptr;

      mrb_bool argc_error = FALSE;
      mrb_value wrong = mrb_protect_error(M, [](mrb_state* M, void*) -> mrb_value {
        return bc2cpp_entry_EntryMade_new(M, 0, nullptr);
      }, nullptr, &argc_error);
      std::printf("new argc error=%d class=%s\\n", argc_error, mrb_obj_classname(M, wrong));
      mrb_value er = bc2cpp_entry_EntryRestInit_new(M, 1, &seven);
      std::printf("new rest class=%s size=%ld\\n", mrb_obj_classname(M, er), fix(mrb_funcall(M, er, "size", 0)));
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
  check.call('the direct new runs the compiled initialize with no dynamic dispatch',
             lines.include?('new class=EntryMade count=8 dispatches=0 exc=0') && lines.include?('new0 count=0'))
  check.call('a raising initialize leaves M->exc and returns the object, as mrb_obj_new does',
             lines.include?('new boom class=EntryBoomInit exc=ArgumentError dispatches=0') &&
               lines.include?('obj_new boom class=EntryBoomInit exc=ArgumentError'))
  check.call('a different argument count takes mrb_obj_new', lines.include?('new argc error=1 class=ArgumentError'))
  check.call('a by-name new runs initialize as mrb_obj_new does', lines.include?('new rest class=EntryRestInit size=1'))
  puts output.lines.last(30).join unless built && lines.last == 'end'
end

if failures.empty?
  puts 'bc2cpp entry header check: PASS'
else
  warn "bc2cpp entry header check: #{failures.size} failure(s)"
  exit 1
end
