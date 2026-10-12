#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check FROZEN_EMBEDDED_STORE (docs/adr/0299): a SETIV on an embedded ivar is a direct struct store,
# where mrb_iv_set raises FrozenError for a frozen object. The store carries the inline frozen
# test unless the closed world proves no instance of a user class can ever be frozen
# (ClosedWorld#user_objects_unfrozen?), in which case the generated hot code is exactly what it was.
#
# 1. Generated code (needs MRBC): the test is present in the open world and in every closed world
#    where a `freeze` can reach a user object (an arbitrary receiver, `&:freeze`, a computed send,
#    native or foreign code that freezes), and absent where every `freeze` is on a builtin literal.
# 2. Behaviour on real mruby (needs MRBC, a mruby build and g++): a frozen receiver raises
#    FrozenError and keeps its value, as the interpreter does, on a 64-bit full-core build, a
#    core-only build and (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32) a 32-bit `mrb_int` build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/embedded_frozen_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

# The classes the stores live in. FzPurse embeds @gold (a Fixnum slot) and @note (a boxed slot).
BASE = <<~'RUBY'
  class FzPurse
    # bc2cpp: (fixnum)
    def initialize(gold)
      @gold = gold
      @note = nil
    end

    def add(n)
      @gold = @gold + n
    end

    def note!(text)
      @note = text
    end

    def gold
      @gold
    end

    def note
      @note
    end
  end

  # Every store is a literal Fixnum, so @n gets an unboxed Fixnum slot (the typed store path).
  class FzTick
    def initialize
      @n = 0
    end

    def tick
      @n = 7
    end

    def n
      @n
    end
  end

  class FzUser
    def bump(purse, n)
      purse.add(n)
    end

    def tick_it(counter)
      counter.tick
    end
  end
RUBY

# What each world appends to BASE. `proven` is whether the closed world must prove the stores
# unfrozen; the other worlds each have one route to a frozen user object.
WORLDS = {
  'no freeze at all' => { extra: '', proven: true },
  'freeze on builtin literals only' => {
    extra: <<~'RUBY', proven: true
      FZ_NAMES = %w[a b].freeze
      FZ_TABLE = { a: 1 }.freeze
      FZ_RANGE = (1..3).freeze
      class FzUser
        def label
          "label".freeze
        end
      end
    RUBY
  },
'freeze on a class constant' => {
    extra: <<~'RUBY', proven: true
      class FzUser
        def lock_class
          FzPurse.freeze
        end
      end
    RUBY
  },
  'freeze on a constant holding an instance' => {
    extra: <<~'RUBY', proven: false
      FZ_BOX = FzPurse.new(1)
      class FzUser
        def lock_box
          FZ_BOX.freeze
        end
      end
    RUBY
  },
  'freeze on an arbitrary receiver' => {
    extra: <<~'RUBY', proven: false
      class FzUser
        def lock(purse)
          purse.freeze
          nil
        end
      end
    RUBY
  },
  'freeze on self' => {
    extra: <<~'RUBY', proven: false
      class FzUser
        def lock_self
          freeze
        end
      end
    RUBY
  },
  'freeze on a call result' => {
    extra: <<~'RUBY', proven: false
      class FzUser
        def lock_made
          FzPurse.new(1).freeze
        end
      end
    RUBY
  },
  '&:freeze' => {
    extra: <<~'RUBY', proven: false
      class FzUser
        def lock_all(list)
          list.each(&:freeze)
        end
      end
    RUBY
  },
  'send(:freeze)' => {
    extra: <<~'RUBY', proven: false
      class FzUser
        def lock_send(obj)
          obj.send(:freeze)
        end
      end
    RUBY
  },
  'a computed send' => {
    extra: <<~'RUBY', proven: false
      class FzUser
        def call_named(obj, name)
          obj.send(name)
        end
      end
      FZ_NAME = "freeze"
    RUBY
  }
}.freeze

# The text of one compiled method, from its header to the next one.
chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
FROZEN_TEST = 'mrb_frozen_p(mrb_obj_ptr(self))'
OWNERS = %w[FzPurse FzTick FzUser].freeze
STORES = %w[FzPurse#add FzPurse#note! FzTick#tick].freeze

# -- 1. generated code -----------------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  WORLDS.each do |name, world|
    Dir.mktmpdir do |dir|
      code, = runtime.generate(BASE + world[:extra], dir, closed: true, only_owners: OWNERS)
      STORES.each do |m|
        text = chunk.call(code, m)
        embedded = text.include?('direct struct field write')
        check.call("#{name}: #{m} stores into the embedded field", embedded)
        check.call(world[:proven] ? "#{name}: #{m} carries no frozen test (proven unfrozen)" : "#{name}: #{m} tests for a frozen self before it stores",
                   text.include?(FROZEN_TEST) == !world[:proven])
        next if world[:proven] || !embedded

        check.call("#{name}: #{m} tests before the store, so a frozen self keeps its value",
                   (tested = text.index(FROZEN_TEST)) && tested < text.index(/\)->ivar_\w+ = /))
      end
    end
  end

  Dir.mktmpdir do |dir|
    code, = runtime.generate(BASE, dir, closed: false, only_owners: OWNERS)
    check.call('NEG: the open world cannot prove it, so both stores test',
               STORES.all? { |m| chunk.call(code, m).include?(FROZEN_TEST) })
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- the world's outside sources ---------------------------------------------------------------

# The fixture runtime cannot add sources to the closed world (they come from the build's own gem
# list), so the native and foreign Ruby scans are judged on ClosedWorld itself.
puts '== outside sources'
require_relative '../../tools/bc2cpp/closed_world'
Dir.mktmpdir do |dir|
  world = lambda do |native: nil, ruby: nil|
    natives = native ? [File.join(dir, 'n.cxx').tap { |f| File.write(f, native) }] : []
    rubies = ruby ? [File.join(dir, 'f.rb').tap { |f| File.write(f, ruby) }] : []
    ClosedWorld.new(ireps: {}, registry: Hash.new { |h, k| h[k] = [] }, class_decls: {}, walked: Set.new,
                    native_paths: natives, ruby_paths: rubies).user_objects_unfrozen?
  end
  check.call('no outside source: nothing freezes a user object', world.call)
  check.call('a project native calling mrb_obj_freeze can freeze one',
             !world.call(native: "void f(mrb_state* M, mrb_value v) { mrb_obj_freeze(M, v); }\n"))
  check.call('a project native setting the frozen flag can',
             !world.call(native: "void f(RBasic* o) { MRB_SET_FROZEN_FLAG(o); }\n") &&
               !world.call(native: "void f(RBasic* o) { o->frozen = 1; }\n"))
  check.call('a project native sending freeze by name can',
             !world.call(native: "void f(mrb_state* M, mrb_value v) { mrb_funcall(M, v, \"freeze\", 0); }\n") &&
               !world.call(native: "void f(mrb_state* M, mrb_value v) { mrb_funcall_id(M, v, MRB_SYM(freeze), 0); }\n"))
  check.call('NEG: a native that only registers a method named freeze, or reads the flag, cannot',
             world.call(native: "void g(mrb_state* M, RClass* c) { mrb_define_method(M, c, \"freeze\", nullptr, MRB_ARGS_NONE()); }\n") &&
               world.call(native: "bool f(RBasic* o) { return o->frozen == 1; }\n"))
  check.call('foreign Ruby that spells freeze can freeze one', !world.call(ruby: "def lock(x)\n  x.freeze\nend\n"))
  check.call('NEG: foreign Ruby that never spells it cannot', world.call(ruby: "def lock(x)\n  x.dup\nend\n"))
end

# -- 2. behaviour ----------------------------------------------------------------------------

BODY = <<~'CPP'
  // The value, or the exception class and message.
  static void fz_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                      const mrb_value* argv = nullptr) {
    mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
    if (M->exc) {
      mrb_value e = mrb_obj_value(M->exc);
      M->exc = nullptr;
      mrb_value msg = (mrb_funcall)(M, e, "message", 0);
      std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
    } else {
      show(M, label, r);
    }
  }
  static int scenario(mrb_state* M) {
    // mruby's mrblib (absent from a bare core) defines these.
    if (!mrb_class_defined(M, "FrozenError")) mrb_define_class(M, "FrozenError", M->eStandardError_class);
    mrb_value user = mrb_obj_new(M, mrb_class_get(M, "FzUser"), 0, nullptr);
    mrb_value ten = mrb_fixnum_value(10), two = mrb_fixnum_value(2);
    mrb_value purse = mrb_obj_new(M, mrb_class_get(M, "FzPurse"), 1, &ten);
    mrb_value a_purse_two[] = { purse, two };
    mrb_value text = mrb_str_new_lit(M, "memo");
    fz_call(M, "add before", user, "bump", 2, a_purse_two);
    fz_call(M, "note! before", purse, "note!", 1, &text);
    fz_call(M, "lock", user, "lock", 1, &purse);
    fz_call(M, "frozen?", purse, "frozen?");
    fz_call(M, "add after (fixnum slot)", user, "bump", 2, a_purse_two);
    fz_call(M, "note! after (boxed slot)", purse, "note!", 1, &text);
    fz_call(M, "gold after", purse, "gold");
    fz_call(M, "note after", purse, "note");
    mrb_value fresh = mrb_obj_new(M, mrb_class_get(M, "FzPurse"), 1, &ten);
    mrb_value a_fresh_two[] = { fresh, two };
    fz_call(M, "an unfrozen purse still adds", user, "bump", 2, a_fresh_two);
    mrb_value counter = mrb_obj_new(M, mrb_class_get(M, "FzTick"), 0, nullptr);
    fz_call(M, "lock counter", user, "lock", 1, &counter);
    fz_call(M, "tick after (typed slot)", user, "tick_it", 1, &counter);
    fz_call(M, "n after", counter, "n");
    return 0;
  }
CPP

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['mrb_int 64, full-core', full, true, ENV['MRBC'], ''] if full
builds << ['mrb_int 64, core only', runtime.core, false, ENV['MRBC'], ''] if runtime.core
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], true, ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
end
builds.clear unless ENV['MRBC'] && runtime.compiler?
puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or BC2CPP_MRUBY_CORE) and have g++' if builds.empty?

values = ->(sections, name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }

builds.each do |label, build, full_flag, mrbc, flags|
  puts "== fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = [saved.last, flags].compact.reject(&:empty?).join(' ')
  begin
    Dir.mktmpdir do |dir|
      source = BASE + WORLDS.fetch('freeze on an arbitrary receiver')[:extra]
      _code, err = runtime.generate(source, dir, closed: true, only_owners: OWNERS)
      built, output = runtime.run(dir, err, OWNERS, BODY, build: build, full: full_flag)
      check.call('the fixture compiles and runs against real mruby', built)
      next unless built

      sections = runtime.sections(output)
      interpreted = values.call(sections, 'interpreted')
      compiled = values.call(sections, 'compiled')
      puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)",
                 interpreted.size == 12 && interpreted == compiled)
      text = interpreted.join("\n")
      check.call('a frozen receiver raises FrozenError from both stores and keeps its value and note',
                 text.include?('add after (fixnum slot) => raised FrozenError') &&
                   text.include?('note! after (boxed slot) => raised FrozenError') &&
                   text.include?('gold after => 12') && text.include?('note after => "memo"'))
      check.call('the typed Fixnum slot raises FrozenError too and keeps its value',
                 text.include?('tick after (typed slot) => raised FrozenError') && text.include?('n after => 0'))
      check.call('an unfrozen purse still stores', text.include?('an unfrozen purse still adds => 12'))
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

if failures.empty?
  puts 'bc2cpp embedded frozen check: PASS'
else
  warn "bc2cpp embedded frozen check: #{failures.size} failure(s)"
  exit 1
end
