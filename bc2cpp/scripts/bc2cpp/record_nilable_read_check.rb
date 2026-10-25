#!/usr/bin/env ruby
# frozen_string_literal: true

# RECORD_NILABLE_READ: a record read `@slot[:key]` enters the exact-class flow as its stored classes plus nil, so the
# flow's truthiness narrowing makes `@slot[:key] || []` and `return unless x` exact receivers. Generated end to end
# by bc2cpp.rb (no mruby build needed); BC2CPP_RECORD_NILABLE_READS=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/record_nilable_read_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('record_nilable_read_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Item
    def initialize; @n = 1; end
    def value; @n; end
  end
  class ObjectScene
    def initialize; @record_items = {}; @record_active = nil; end
    def start; @record_items[:item] = Item.new; nil; end
    def remove; @record_items.delete(:item); nil; end
    def forget; @record_items[:item] = nil; nil; end
    def activate; @record_active = @record_items[:item]; nil; end
    def active_value; @record_active.value; end
    def guarded_value; item = @record_items[:item]; return 0 unless item; item.value; end
  end
  class ObjectLeak
    def initialize; @record_leaked = {}; end
    def start; @record_leaked[:item] = Item.new; nil; end
    def hand_out; @record_leaked; end
    def value; item = @record_leaked[:item]; return 0 unless item; item.value; end
  end
  class ObjectUnknown
    def initialize; @record_unknown = {}; end
    def make_item; Item.new; end
    def start; @record_unknown[:item] = make_item; nil; end
    def value; item = @record_unknown[:item]; return 0 unless item; item.value; end
  end
  class Scene
    def initialize
      @ui = {}
      nil
    end

    def start
      @ui[:sprites] = []
      @ui[:list] = make_list
      nil
    end

    def make_list
      [1].map { |x| x }
    end

    def total
      (@ui[:sprites] || []).size
    end

    def each_sprite
      (@ui[:sprites] || []).each { |s| s }
    end

    def guarded
      s = @ui[:sprites]
      return 0 unless s
      s.size
    end

    def plain
      @ui[:sprites].size
    end

    def call_stored
      (@ui[:list] || []).size
    end
  end

  class Leaky
    def initialize
      @h = {}
      nil
    end

    def start
      @h[:items] = []
      nil
    end

    def hand_out
      @h
    end

    def total
      (@h[:items] || []).size
    end
  end
RUBY

# { "Owner#name" => generated body } of one run.
bodies = lambda do |flag|
  ENV['BC2CPP_RECORD_NILABLE_READS'] = flag
  Dir.mktmpdir('record_nilable_read') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Scene Leaky Item ObjectScene ObjectLeak ObjectUnknown])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  ENV.delete('BC2CPP_RECORD_NILABLE_READS')
end
on = bodies.call('1')
off = bodies.call('0')
exact_size = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :size') }

check.call('`@ui[:k] || []` is an exact Array for size', exact_size.call(on['Scene#total']))
check.call('without the read it keeps its class chain', !exact_size.call(off['Scene#total']))
# The by-name block send, or its owner call carrying the block (BLOCK_OWNER_CALL).
by_name_block = /mrb_funcall_with_block\(|bc2cpp_owner_call\(M, [^;]*BC2CPP_OWNERS\([^)]*\), (?!mrb_nil_value\(\))/
check.call('`(@ui[:k] || []).each` drops its guard and by-name fallback',
           !on['Scene#each_sprite'].match?(by_name_block) &&
           !on['Scene#each_sprite'].include?('GUARDED_BLOCK_INLINE'))
check.call('without the read `each` keeps its fallback', off['Scene#each_sprite'].match?(by_name_block))
check.call('`return 0 unless x` narrows the read to Array', exact_size.call(on['Scene#guarded']))
check.call('an unnarrowed read keeps its nil test (NILABLE_RECEIVER) before the exact Array body',
           on['Scene#plain'].include?('NILABLE_RECEIVER :size -- receiver is nil or exactly Array') &&
           on['Scene#plain'].include?('bc2cpp_nil_receiver(') && exact_size.call(on['Scene#plain']))
check.call('without the read a plain read has no nil test', !off['Scene#plain'].include?('NILABLE_RECEIVER'))
check.call('a key stored from a call result stays unknown', !exact_size.call(on['Scene#call_stored']))
check.call('a record that escapes gives no read class', !exact_size.call(on['Leaky#total']))

ENV['BC2CPP_RECORD_OBJECT_READS'] = '0'
objects_off = bodies.call('1')
ENV.delete('BC2CPP_RECORD_OBJECT_READS')
check.call('a stored object read flows through an ivar pool to its exact non-nil call',
           on['ObjectScene#active_value'].to_s.include?('NILABLE_RECEIVER :value') &&
             !objects_off['ObjectScene#active_value'].to_s.include?('NILABLE_RECEIVER :value'))
check.call('a truthiness check narrows a stored object to its exact class',
           on['ObjectScene#guarded_value'].to_s.match?(/(?:MONO_EXACT_FLOW|CLOSED_WORLD_EXACT_CLASS) :value/) &&
             !objects_off['ObjectScene#guarded_value'].to_s.match?(/(?:MONO_EXACT_FLOW|CLOSED_WORLD_EXACT_CLASS) :value/))

check.call('an escaped object record yields no exact object read proof',
           !on['ObjectLeak#value'].to_s.match?(/(?:MONO_EXACT_FLOW|CLOSED_WORLD_EXACT_CLASS) :value/))
check.call('an unproven object factory is not treated as a constructor proof',
           !on['ObjectUnknown#value'].to_s.match?(/(?:MONO_EXACT_FLOW|CLOSED_WORLD_EXACT_CLASS) :value/))

Dir.mktmpdir('record-object-constructor') do |dir|
  replaced, = Bc2cppFixtureRuntime.generate(SOURCE + "class Item; def self.new; 'replacement'; end; end", dir,
                                           only_owners: %w[Scene Leaky Item ObjectScene ObjectLeak ObjectUnknown Item.singleton])
  body = replaced[/^mrb_value ObjectScene_guarded_value_impl[^\n]*\n.*?^\}/m].to_s
  check.call('a replaced constructor withdraws the stored Item class proof',
             !body.match?(/(?:MONO_EXACT_FLOW|CLOSED_WORLD_EXACT_CLASS) :value/))
end

unless ENV['CC_GENERATED_ONLY'] == '1'
  build = Bc2cppFixtureRuntime.full_or_build
  if build
    Dir.mktmpdir('record-object-runtime') do |dir|
      owners = %w[Scene Leaky Item ObjectScene ObjectLeak ObjectUnknown]
      code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: owners)
      driver = <<~'RUBY'
        show = lambda do |name, &block|
          begin
            puts "#{name}: #{block.call.inspect}"
          rescue Exception => e
            puts "#{name}: #{e.class}: #{e.message}"
          end
        end
        s = ObjectScene.new
        show.call('missing') { s.guarded_value }
        show.call('inactive') { s.active_value }
        s.start
        s.activate
        show.call('stored') { s.guarded_value }
        show.call('active') { s.active_value }
        s.remove
        show.call('deleted') { s.guarded_value }
        show.call('active snapshot') { s.active_value }
        s.activate
        show.call('activated missing') { s.active_value }
        s.start
        s.forget
        show.call('explicit nil') { s.guarded_value }
        l = ObjectLeak.new
        l.start
        show.call('escaped before mutation') { l.value }
        l.hand_out[:item] = 'wrong class'
        show.call('escaped after mutation') { l.value }
        puts 'end'
      RUBY
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          mrb_load_string(M, R"REC(#{driver})REC");
          std::fflush(stdout);
          if (M->exc) { mrb_print_error(M); return 1; }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(dir, err, owners, harness, build: build, full: true)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call('record object fixture builds and runs', built)
      check.call('record object values and errors match interpreted mruby',
                 interpreted && interpreted.last == 'end' && interpreted == compiled)
      puts output unless built && interpreted && interpreted == compiled
    end
  else
    puts '  SKIP: no full-core mruby build for record object runtime check'
  end
end

suite.finish!
