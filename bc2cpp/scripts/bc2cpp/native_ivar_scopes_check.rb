#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0332: pin the audited call graph and exercise family isolation and
# withdrawal. Runtime cases include native writes to a Window subclass.
require 'fileutils'
require_relative 'fixture_runtime'
require ENV.fetch('NIS_AUDIT_TOOL') { File.expand_path('../tools/bc2cpp/native_ivar_scopes', __dir__) }

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
expected = NativeIvarScopes::SCOPES

puts '== source audit'
Dir.mktmpdir do |dir|
  paths = NativeIvarScopes::FILES.keys.map do |relative|
    dest = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(ROOT, relative), dest)
    dest
  end
  analyze = ->(native = paths, ruby = []) { NativeIvarScopes.analyze(native, ruby, root: dir).first }
  check.call('audited files scope names to their native families', analyze.call == expected)
  alias_path = File.join(dir, 'lib-alias.cxx')
  File.symlink(paths.first, alias_path)
  check.call('symlink input aliases preserve audit coverage', analyze.call(paths.drop(1) + [alias_path]) == expected)
  NativeIvarScopes::FILES.keys.zip(paths).each do |relative, path|
    check.call("missing input withdraws: #{relative}", analyze.call(paths - [path]).empty?)
    original = File.binread(path)
    File.write(path, original + "\nvoid unexpected_native_caller() {}\n")
    check.call("changed input withdraws: #{relative}", analyze.call.empty?)
    File.binwrite(path, original)
  end
  extra = File.join(dir, 'outside.cxx')
  File.write(extra, 'void f(mrb_state* M, mrb_value other) { window_refresh(M, other); }')
  check.call('outside helper caller withdraws', analyze.call(paths + [extra]).empty?)
  File.write(extra, 'auto callback = &rgss::window_contents_set_direct;')
  check.call('outside function pointer withdraws', analyze.call(paths + [extra]).empty?)
  File.write(extra, "#define caller(name) window_ ## name\ncaller(refresh)(M, other);")
  check.call('outside token-pasted helper caller withdraws', analyze.call(paths + [extra]).empty?)
  %w[spr_init sprite_new_direct plane_init tilemap_init].each do |name|
    File.write(extra, "auto callback = &#{name};")
    check.call("outside viewport receiver entry withdraws: #{name}", analyze.call(paths + [extra]).empty?)
  end
  %w[spr_set_bmp sprite_bitmap_set_direct plane_set_bmp plane_set_bmp_native_body plane_set_bmp_direct].each do |name|
    File.write(extra, "auto callback = &rgss::#{name};")
    check.call("outside bitmap setter reference withdraws: #{name}", analyze.call(paths + [extra]).empty?)
  end
  File.write(extra, 'mrb_iv_set(M, other, MRB_IVSYM(bitmap), value);')
  check.call('outside bitmap spelling poisons only bitmap', analyze.call(paths + [extra]).keys == expected.keys - ['bitmap'])
  saved_bitmap = ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE']
  begin
    ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE'] = '0'
    check.call('bitmap kill switch withdraws only bitmap', analyze.call.keys == expected.keys - ['bitmap'])
  ensure
    ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE'] = saved_bitmap
  end
  File.write(extra, '#define caller(name) spr_ ## name')
  check.call('outside token-pasted Sprite caller withdraws', analyze.call(paths + [extra]).empty?)
  File.write(extra, 'mrb_iv_set(M, other, MRB_IVSYM(viewport), value);')
  check.call('outside viewport spelling poisons only viewport', analyze.call(paths + [extra]).keys == expected.keys - ['viewport'])
  File.write(extra, 'mrb_iv_set(M, other, MRB_IVSYM(contents), value);')
  check.call('outside presym write keeps contents globally poisoned', analyze.call(paths + [extra]).keys == expected.keys - ['contents'])
  File.write(extra, '@cursor_rect = other')
  check.call('foreign Ruby keeps cursor_rect globally poisoned', analyze.call(paths, [extra]).keys == expected.keys - ['cursor_rect'])
  check.call('missing outside source withdraws', analyze.call(paths + [File.join(dir, 'missing.cxx')]).empty?)
  unreadable = false
  begin
    analyze.call(paths + [dir])
  rescue SourceText::Unreadable => e
    unreadable = e.message.include?('cannot read')
  end
  check.call('unreadable outside source raises', unreadable)
  saved = ENV['BC2CPP_NATIVE_IVAR_SCOPES']
  begin
    ENV['BC2CPP_NATIVE_IVAR_SCOPES'] = '0'
    check.call('kill switch withdraws', analyze.call.empty?)
  ensure
    ENV['BC2CPP_NATIVE_IVAR_SCOPES'] = saved
  end
end

SOURCE = <<~RUBY
  class NiBox
    def ni_tag; 7; end
  end
  class NiOther
    def ni_tag; 9; end
  end
  class NiScene
    def initialize; @contents = NiBox.new; @cursor_rect = NiBox.new; @viewport = NiBox.new; @bitmap = NiBox.new; end
    def read_contents; @contents.ni_tag; end
    def read_cursor; @cursor_rect.ni_tag; end
    def read_viewport; @viewport.ni_tag; end
    def read_bitmap; @bitmap.ni_tag; end
    def clear; @contents = nil; end
  end
  module RGSS
    class Window
      def initialize; @contents = NiBox.new; @cursor_rect = NiBox.new; @viewport = NiBox.new; @bitmap = NiBox.new; end
      def read_contents; @contents.ni_tag; end
      def read_cursor; @cursor_rect.ni_tag; end
    def read_viewport; @viewport.ni_tag; end
    def read_bitmap; @bitmap.ni_tag; end
    end
  end
  module RGSS
    class Sprite
      def initialize; @viewport = NiBox.new; @bitmap = NiBox.new; end
      def read_viewport; @viewport.ni_tag; end
    def read_bitmap; @bitmap.ni_tag; end
    end
    class Plane
      def initialize; @viewport = NiBox.new; @bitmap = NiBox.new; end
      def read_viewport; @viewport.ni_tag; end
    def read_bitmap; @bitmap.ni_tag; end
    end
    class Tilemap
      def initialize; @viewport = NiBox.new; @bitmap = NiBox.new; end
      def read_viewport; @viewport.ni_tag; end
    def read_bitmap; @bitmap.ni_tag; end
    end
  end
  class NiSpriteChild < RGSS::Sprite
    def read_child; @viewport.ni_tag; end
    def read_bitmap_child; @bitmap.ni_tag; end
  end
  class NiWindowChild < RGSS::Window
    def read_child; @contents.ni_tag; end
  end
RUBY
OWNERS = %w[NiBox NiOther NiScene RGSS::Window NiWindowChild RGSS::Sprite RGSS::Plane RGSS::Tilemap NiSpriteChild].freeze
body_of = lambda do |code, owner, name|
  code[/^mrb_value #{owner.gsub('::', '__')}_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
direct = lambda do |code, owner, name|
  body = body_of.call(code, owner, name)
  !body.empty? && body.match?(/(?:EXACT_TYPED|CLOSED_WORLD_EXACT_CLASS) :ni_tag /) && !body.include?('bc2cpp_send(')
end
runtime = Bc2cppFixtureRuntime
if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true) if ENV['BC2CPP_KEEP_DIR']
    %w[read_contents read_cursor read_viewport].each do |name|
      check.call("unrelated scene pool: #{name}", direct.call(code, 'NiScene', name))
      check.call("Window remains unknown: #{name}", !direct.call(code, 'RGSS::Window', name) && !body_of.call(code, 'RGSS::Window', name).empty?)
    end
    check.call('unrelated bitmap pool', direct.call(code, 'NiScene', 'read_bitmap'))
    check.call('Window bitmap is independent', direct.call(code, 'RGSS::Window', 'read_bitmap'))
    %w[RGSS::Sprite RGSS::Plane].each do |owner|
      check.call("native bitmap family remains unknown: #{owner}", !direct.call(code, owner, 'read_bitmap') && !body_of.call(code, owner, 'read_bitmap').empty?)
    end
    check.call('Sprite subclass bitmap remains unknown', !direct.call(code, 'NiSpriteChild', 'read_bitmap_child') && !body_of.call(code, 'NiSpriteChild', 'read_bitmap_child').empty?)
    check.call('Window subclass remains unknown',
               !direct.call(code, 'NiWindowChild', 'read_child') && !body_of.call(code, 'NiWindowChild', 'read_child').empty?)
    %w[RGSS::Sprite RGSS::Plane RGSS::Tilemap].each do |owner|
      check.call("native viewport family remains unknown: #{owner}",
                 !direct.call(code, owner, 'read_viewport') && !body_of.call(code, owner, 'read_viewport').empty?)
    end
    check.call('Sprite subclass viewport remains unknown',
               !direct.call(code, 'NiSpriteChild', 'read_child') && !body_of.call(code, 'NiSpriteChild', 'read_child').empty?)
    scenarios = [
      ['native name spelling', SOURCE, { native: [['outside.cxx', 'const char* iv = "@contents";']] }, {}],
      ['foreign Ruby name spelling', SOURCE, { foreign: [['outside.rb', '@contents = 1']] }, {}],
      ['reflection', SOURCE + "class NiScene; def poke(v); instance_variable_set(:@contents, v); end; end\n", {}, {}],
      ['shared mixin family', SOURCE + "module NiShared; def value; @contents; end; end\nclass NiScene; include NiShared; end\nclass RGSS::Window; include NiShared; end\n", {}, {}],
      ['open world', SOURCE, { closed: false }, {}],
      ['kill switch', SOURCE, {}, { 'BC2CPP_NATIVE_IVAR_SCOPES' => '0' }]
    ]
    scenarios.each do |name, source, options, env|
      Dir.mktmpdir do |world|
        saved = env.to_h { |k, _| [k, ENV[k]] }
        begin
          env.each { |k, v| ENV[k] = v }
          other_code, = runtime.generate(source, world, only_owners: OWNERS, **options)
          check.call("withdrawal: #{name}",
                     !direct.call(other_code, 'NiScene', 'read_contents') && !body_of.call(other_code, 'NiScene', 'read_contents').empty?)
        ensure
          saved.each { |k, v| ENV[k] = v }
        end
      end
    end
    [
      ['viewport native spelling', SOURCE, { native: [['outside.cxx', 'const char* iv = "@viewport";']] }],
      ['viewport foreign Ruby', SOURCE, { foreign: [['outside.rb', '@viewport = 1']] }],
      ['viewport reflection', SOURCE + "class NiScene; def poke(v); instance_variable_set(:@viewport, v); end; end\n", {}],
      ['viewport shared Sprite mixin', SOURCE + "module NiShared; def value; @viewport; end; end\nclass NiScene; include NiShared; end\nclass RGSS::Sprite; include NiShared; end\n", {}]
    ].each do |name, source, options|
      Dir.mktmpdir do |world|
        other_code, = runtime.generate(source, world, only_owners: OWNERS, **options)
        check.call("withdrawal: #{name}", !direct.call(other_code, 'NiScene', 'read_viewport') &&
                   !body_of.call(other_code, 'NiScene', 'read_viewport').empty?)
      end
    end
    [
      ['bitmap native spelling', SOURCE, { native: [['outside.cxx', 'const char* slot = "@bitmap";']] }, {}],
      ['bitmap foreign Ruby', SOURCE, { foreign: [['outside.rb', '@bitmap = 1']] }, {}],
      ['bitmap reflection', SOURCE + "class NiScene; def poke(v); instance_variable_set(:@bitmap, v); end; end\n", {}, {}],
      ['bitmap attr writer', SOURCE + "class NiScene; attr_writer :bitmap; end\n", {}, {}],
      ['bitmap shared Sprite mixin', SOURCE + "module NiShared; def value; @bitmap; end; end\nclass NiScene; include NiShared; end\nclass RGSS::Sprite; include NiShared; end\n", {}, {}],
      ['bitmap kill switch', SOURCE, {}, { 'BC2CPP_NATIVE_BITMAP_IVAR_SCOPE' => '0' }]
    ].each do |name, source, options, env|
      Dir.mktmpdir do |world|
        saved = env.to_h { |key,| [key, ENV[key]] }
        begin
          env.each { |key, value| ENV[key] = value }
          other_code, = runtime.generate(source, world, only_owners: OWNERS, **options)
          check.call("withdrawal: #{name}", !direct.call(other_code, 'NiScene', 'read_bitmap') && !body_of.call(other_code, 'NiScene', 'read_bitmap').empty?)
        ensure
          saved.each { |key, value| ENV[key] = value }
        end
      end
    end
    builds = []
    if ENV['NIS_GENERATED_ONLY'] != '1'
      full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] && runtime.full_or_build)
      builds << ['full-core', full, true] if full
      builds << ['core-only', runtime.core, false] if runtime.core && ENV['NIS_FULL_ONLY'] != '1'
    end
    if !builds.empty? && runtime.compiler?
      body = <<~'CPP'
        static mrb_value native_bitmap_set(mrb_state* M, mrb_value self) {
          mrb_value value = mrb_get_arg1(M);
          mrb_iv_set(M, self, mrb_intern_lit(M, "@bitmap"), value);
          return value;
        }
        static int scenario(mrb_state* M) {
          mrb_value scene = mrb_obj_new(M, mrb_class_get(M, "NiScene"), 0, nullptr);
          call(M, "contents", scene, "read_contents");
          call(M, "cursor", scene, "read_cursor");
          call(M, "viewport", scene, "read_viewport");
          call(M, "bitmap", scene, "read_bitmap");
          call(M, "clear", scene, "clear");
          call(M, "nil contents", scene, "read_contents");
          mrb_value win = mrb_obj_new(M, mrb_class_get(M, "NiWindowChild"), 0, nullptr);
          mrb_value other = mrb_obj_new(M, mrb_class_get(M, "NiOther"), 0, nullptr);
          mrb_iv_set(M, win, mrb_intern_lit(M, "@contents"), other);
          mrb_iv_set(M, win, mrb_intern_lit(M, "@cursor_rect"), other);
          call(M, "native contents", win, "read_contents");
          call(M, "native cursor", win, "read_cursor");
          call(M, "native subclass", win, "read_child");
          const char* owners[] = {"Window", "Sprite", "Plane", "Tilemap"};
          for (const char* owner : owners) {
            RClass* klass = mrb_class_get_under(M, mrb_module_get(M, "RGSS"), owner);
            mrb_value receiver = mrb_obj_new(M, klass, 0, nullptr);
            mrb_iv_set(M, receiver, mrb_intern_lit(M, "@viewport"), other);
            call(M, owner, receiver, "read_viewport");
          }
          mrb_value sprite = mrb_obj_new(M, mrb_class_get(M, "NiSpriteChild"), 0, nullptr);
          mrb_iv_set(M, sprite, mrb_intern_lit(M, "@viewport"), other);
          call(M, "native Sprite subclass", sprite, "read_child");
          const char* bitmap_owners[] = {"Sprite", "Plane"};
          for (const char* owner : bitmap_owners) {
            RClass* klass = mrb_class_get_under(M, mrb_module_get(M, "RGSS"), owner);
            mrb_define_method(M, klass, "bitmap=", native_bitmap_set, MRB_ARGS_REQ(1));
            mrb_value receiver = mrb_obj_new(M, klass, 0, nullptr);
            mrb_funcall(M, receiver, "bitmap=", 1, other);
            call(M, owner, receiver, "read_bitmap");
          }
          mrb_funcall(M, sprite, "bitmap=", 1, other);
          call(M, "native Sprite bitmap subclass", sprite, "read_bitmap_child");
          return 0;
        }
      CPP
      builds.each do |label, build, full|
        built, output = runtime.run(dir, err, OWNERS, body, build: build, full: full)
        sections = runtime.sections(output).transform_values { |lines| lines.reject { |l| l.start_with?('  dispatches=') } }
        # Core-only omits the mrblib that installs NoMethodError's class.
        error = full ? 'NoMethodError' : 'Exception'
        matches = built && sections['compiled'] == sections['interpreted'] &&
                  output.include?('bitmap => 7') && output.include?('native Sprite bitmap subclass => 9') &&
                  output.include?('native subclass => 9') && output.include?('native Sprite subclass => 9') &&
                  %w[Window Sprite Plane Tilemap].all? { |owner| output.include?("#{owner} => 9") } && output.include?("nil contents => raised #{error}")
        check.call("#{label}: compiled matches interpreted, including nil and native Window writes", matches)
        warn output unless matches
      end
    else
      puts '-- SKIP runtime: set BC2CPP_MRUBY_FULL or BC2CPP_MRUBY_CORE'
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native ivar scopes check: PASS'
