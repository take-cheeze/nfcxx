#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_DATA_OWNERS (CodeGen#native_data_owner?): a class native code makes MRB_TT_DATA, and any subclass of it,
# never gets an embedded ivar struct, since a native owns its DATA_PTR. The unit part feeds the native scan each form
# of MRB_SET_INSTANCE_TT; the world part checks the world's natives all resolve and name RGSS::Window; the fixture
# part generates a data class whose Ruby #initialize calls a native one that stores its own payload in DATA_PTR (as
# RGSS::Window's _rgss1_initialize does), runs it interpreted and compiled, and checks the payload survives the
# ivar stores. The fixture part needs a host mrbc, the behavioural one a full-core libmruby.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_owner_map'

suite = FixtureCheck.new('native_data_embed_check')

SCAN = <<~C
  #include <mruby.h>
  void nd_init(mrb_state* M) {
    struct RClass* mod = mrb_define_module(M, "Nm");
    RClass* nd = mrb_define_class_under(M, mod, "Nd", M->object_class);
    MRB_SET_INSTANCE_TT(nd, MRB_TT_DATA);
    RClass* top = mrb_define_class(M, "Nt", M->object_class);
    MRB_SET_INSTANCE_TT(top, MRB_TT_DATA);
    RClass* arr = mrb_define_class(M, "Na", M->array_class);
    MRB_SET_INSTANCE_TT(arr, MRB_TT_ARRAY);
  }
C

Dir.mktmpdir('bc2cpp-native-data-embed') do |dir|
  path = File.join(dir, 'nd.c')
  File.write(path, SCAN)
  classes, unknown = NativeOwnerMap.data_instance_classes([path])
  suite.check('a class defined under a module variable resolves', classes.include?('Nm::Nd'))
  suite.check('a top-level class resolves', classes.include?('Nt'))
  suite.check('a non-MRB_TT_DATA instance type is not a data class', !classes.include?('Na'))
  suite.check('every call resolves', unknown.zero?)

  opaque = File.join(dir, 'opaque.c')
  File.write(opaque, "void f(mrb_state* M) {\n  MRB_SET_INSTANCE_TT(lookup(M), MRB_TT_DATA);\n}\n")
  suite.check('a computed class expression counts as unresolved', NativeOwnerMap.data_instance_classes([opaque]).last == 1)
end

world, world_unknown = NativeOwnerMap.data_instance_classes(Bc2cppFixtureRuntime.closed_world_native_srcs)
suite.check("the world's MRB_TT_DATA classes all resolve (#{world_unknown} do not)", world_unknown.zero?)
suite.check("RGSS::Window, whose Ruby #initialize calls its native one, is a native data class (#{world.to_a.sort.join(', ')})",
            world.include?('RGSS::Window'))

suite.require_mrbc!

# _n_init replaces DATA_PTR with a node of markers; _n_intact reports whether every marker survived.
NATIVE = <<~'CPP'
  #include <mruby.h>
  #include <mruby/class.h>
  #include <mruby/data.h>
  struct NdNode { mrb_int marker[8]; };
  static NdNode nd_nodes[8];
  static int nd_used = 0;
  static const mrb_data_type nd_node_type = {"NdNode", nullptr};
  mrb_value nd_native_init(mrb_state* M, mrb_value self) {
    NdNode* node = &nd_nodes[nd_used++ % 8];
    for (mrb_int& m : node->marker) m = 0x5eed;
    mrb_data_init(self, node, &nd_node_type);
    return self;
  }
  mrb_value nd_native_intact(mrb_state* M, mrb_value self) {
    const NdNode* node = static_cast<const NdNode*>(DATA_PTR(self));
    for (mrb_int m : node->marker) if (m != 0x5eed) return mrb_false_value();
    return mrb_true_value();
  }
  void nd_native_install(mrb_state* M) {
    struct RClass* mod = mrb_define_module(M, "Nm");
    RClass* nd = mrb_define_class_under(M, mod, "Nd", M->object_class);
    MRB_SET_INSTANCE_TT(nd, MRB_TT_DATA);
    mrb_define_method(M, nd, "_n_init", nd_native_init, MRB_ARGS_NONE());
    mrb_define_method(M, nd, "_n_intact", nd_native_intact, MRB_ARGS_NONE());
  }
CPP

SOURCE = <<~RUBY
  module Nm
    class Nd
      attr_reader :a

      def initialize(a)
        _n_init
        @a = a
        @b = a + 1
      end

      def sum = @a + @b
    end

    class Ns < Nd
      def initialize(a)
        super
        @c = a
      end

      def all = sum + @c
    end
  end

  class Pd
    def initialize(a)
      @a = a
      @b = a + 1
    end

    def sum = @a + @b
  end
RUBY

# The fixture's bytecode defines the classes first, so the native install reopens them, and Ns (created before Nd
# became a data class) is switched by hand.
BODY = <<~'CPP'
  void nd_native_install(mrb_state* M);
  static int scenario(mrb_state* M) {
    nd_native_install(M);
    MRB_SET_INSTANCE_TT(mrb_class_get_under(M, mrb_module_get(M, "Nm"), "Ns"), MRB_TT_DATA);
    std::fflush(stdout);
    mrb_load_string(M, R"NDE(
      o = Nm::Nd.new(3)
      puts "Nd a=#{o.a} sum=#{o.sum} intact=#{o._n_intact}"
      s = Nm::Ns.new(4)
      puts "Ns all=#{s.all} intact=#{s._n_intact}"
      puts "Pd sum=#{Pd.new(5).sum}"
      puts 'end'
    )NDE");
    std::fflush(stdout);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    return 0;
  }
CPP

OWNERS = %w[Nm::Nd Nm::Ns Pd].freeze

Dir.mktmpdir('bc2cpp-native-data-embed') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS,
                                                         native: [['nd_native.cpp', NATIVE]])
  # The EMBED log lists candidates before select_embeddings; the structs the code builds are the decision.
  structs = code.scan(/mrb_data_init\(self, embedded, &(\w+)_ivars_type\);/).flatten.uniq
  suite.check("the plain class embeds its ivars (control; built: #{structs.inspect})", structs.include?('Pd'))
  suite.check('the native data class and its subclass keep their ivars in iv_tbl',
              structs.none? { |name| name.match?(/N[ds]\z/) })

  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, BODY, build: build, full: true,
                                                                     extra_srcs: [File.join(dir, 'nd_native.cpp')])
    suite.check('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    expected = ['Nd a=3 sum=7 intact=true', 'Ns all=13 intact=true', 'Pd sum=11', 'end']
    suite.check("the interpreted run keeps the native payload (#{sections['interpreted'].inspect})",
                sections['interpreted'] == expected)
    suite.check("the compiled run keeps the native payload (#{sections['compiled'].inspect})",
                sections['compiled'] == expected)
    puts output.lines.last(30).join unless built
  end
end

suite.finish!
