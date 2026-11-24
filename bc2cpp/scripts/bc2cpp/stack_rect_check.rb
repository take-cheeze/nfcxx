#!/usr/bin/env ruby
# frozen_string_literal: true

# Check STACK_RECT (tools/bc2cpp/codegen_stack_rect.rb): a `Rect.new(x, y, w, h)` used only as a rect argument of
# Bitmap#blt / #stretch_blt / #copy_blt keeps its fields in the frame and the draw takes them.
#
#   1. audit (no mrbc): the world's mruby-rgss/src/lib.cxx draws keep no Rect. Each *_rects_direct entry copies its
#      fields into a local Rect and hands that to the same body as the object entry; each object entry reads its Rect
#      argument only through DataType<Rect>::get; each pixel and deferred-record function takes `const Rect&`. A
#      mutated source (an entry that stores the Rect, a body that takes a mutable one) is refused.
#   2. placement (MRBC): POSITIVE's sites take the fields and build no Rect, a guarded draw builds it only in its
#      dispatch arm; NEGATIVE's escapes (returned, stored, captured by a block, read, handed to Ruby, two guarded
#      draws) keep their Rects, byte-identical to BC2CPP_STACK_RECT=0, which places none at all.
#   3. parity: the RGSS natives are not in the fixture runtime, so a stub (STUB below) stands in for the entries
#      the generated code calls and for the classes the interpreter calls; both runs print every draw with its rect.
#
# A world whose include/rgss_construct.hxx lacks the entries (an older pin) compiles without the plan: the audit and
# placement then print SKIP.
#
# Usage: [MRBC=path/to/host/mrbc] ruby scripts/bc2cpp/stack_rect_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/world_root'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

LIB = File.join(BC2CPP_WORLD_ROOT, 'mruby-rgss/src/lib.cxx')
HEADER = File.join(BC2CPP_WORLD_ROOT, 'include/rgss_construct.hxx')
ENTRIES = %w[bitmap_blt_rects_direct bitmap_stretch_blt_rects_direct bitmap_copy_blt_rects_direct].freeze
OBJECT_ENTRIES = { 'bitmap_blt_direct' => 'source_rect', 'bitmap_stretch_blt_direct' => nil,
                   'bitmap_copy_blt_direct' => nil }.freeze
# The bodies the entries share, with the Rect parameters each takes.
BODIES = { 'blt_rect' => %w[rc_fields], 'copy_blt_rect' => %w[rc_fields],
           'stretch_blt_rects' => %w[dr_fields sr_fields] }.freeze
PIXELS = %w[blt_pixels copy_pixels stretch_pixels deferred_record deferred_stretch].freeze

# The text of the definition of +name+ in +src+ (signature through the closing brace at column 0), or nil.
def definition(src, name)
  start = src.index(/^(?:static )?(?:mrb_value|void|bool) #{name}\(/)
  return nil unless start

  stop = src.index(/^\}\n/, start)
  stop && src[start..stop]
end

# Why +src+ lets a draw keep a Rect, or nil when it keeps none.
def audit(src)
  ENTRIES.each do |name|
    body = definition(src, name) or return "#{name} is not defined"
    return "#{name} does not copy its fields into a local Rect" unless body.include?('rect_of(')
    return "#{name} stores its fields" if body.match?(/mrb_iv_set|mrb_ary_push|static\s+const\s+RectFields|static\s+Rect\b/)
  end
  BODIES.each do |name, params|
    body = definition(src, name) or return "#{name} is not defined"
    params.each { |param| return "#{name} takes #{param} mutable" unless body.include?("const Rect* #{param}") }
    return "#{name} stores a Rect" if body.match?(/mrb_iv_set|mrb_ary_push|mrb_obj_new/)
  end
  OBJECT_ENTRIES.each_key do |name|
    body = definition(src, name) or return "#{name} is not defined"
    return "#{name} stores its Rect argument" if body.match?(/mrb_iv_set|mrb_ary_push/)
  end
  # Every read of a Rect object argument in the bodies goes through DataType<Rect>::get.
  %w[blt_rect copy_blt_rect stretch_blt_rects].each do |name|
    body = definition(src, name)
    %w[source_rect srect drect_v srect_v].each do |param|
      next unless body.match?(/\b#{param}\b/)

      uses = body.scan(/\b#{param}\b/).size - 1 # the parameter itself
      gets = body.scan(/DataType<Rect>::get\(M, #{param}\)/).size
      return "#{name} reads #{param} outside DataType<Rect>::get" unless uses == gets
    end
  end
  PIXELS.each do |name|
    sig = src[/^(?:static )?(?:mrb_value|void|bool) #{name}\([^)]*\)/m] or return "#{name} is not declared"
    sig.scan(/(?:const )?Rect&?\*? \w+/).each do |param|
      return "#{name} takes #{param} mutable" unless param.start_with?('const Rect& ')
    end
  end
  nil
end

world_has_entries = File.exist?(HEADER) && ENTRIES.all? { |e| File.read(HEADER).include?("#{e}(") }

puts '== audit'
if world_has_entries
  src = File.read(LIB)
  check.call('the world\'s draws keep no Rect', audit(src).nil?)
  mutations = {
    'an entry stores its fields' => ['  const Rect rc = rect_of(source_rect);',
                                     "  const Rect rc = rect_of(source_rect);\n  mrb_iv_set(M, self, 0, self);"],
    'a body takes its Rect mutable' => ['const Rect* rc_fields,', 'Rect* rc_fields,'],
    'a pixel loop takes a mutable Rect' => ['                       const Rect& rc,', '                       Rect& rc,'],
    'a body reads the Rect object by hand' => ['rc_fields ? *rc_fields : DataType<Rect>::get(M, source_rect);',
                                               'rc_fields ? *rc_fields : *(Rect*)DATA_PTR(source_rect);']
  }
  mutations.each do |what, (from, to)|
    raise "mutation #{what} does not apply" unless src.include?(from)

    check.call("refused: #{what}", !audit(src.sub(from, to)).nil?)
  end
else
  puts "  SKIP: #{HEADER} declares no RectFields entries"
end

POSITIVE = <<~RUBY
  class SrPos
    def initialize
      @bmp = Bitmap.new(8, 8)
      @src = Bitmap.new(8, 8)
    end

    def inline(x)
      @bmp.blt(x, 0, @src, Rect.new(x, 1, 2, 3))
      :ok
    end

    def local(x)
      r = Rect.new(x, 1, 2, 3)
      @bmp.blt(0, 0, @src, r, 128)
      :ok
    end

    def two(x)
      @bmp.stretch_blt(Rect.new(x, 0, 4, 4), @src, Rect.new(0, x, 2, 2), 7)
      :ok
    end

    def half(x, dst)
      @bmp.stretch_blt(dst, @src, Rect.new(x, x, 1, 1))
      :ok
    end

    def copy(x)
      @bmp.copy_blt(1, 2, @src, Rect.new(x, 0, 2, 2))
      :ok
    end

    def float(x)
      @bmp.blt(0, 0, @src, Rect.new(x + 0.5, 1, 2, 3))
      :ok
    end

    def bad(x, y)
      @bmp.blt(0, 0, @src, Rect.new(x, y, 2, 3))
      :ok
    end

    def guarded(b, x)
      b.blt(0, 0, @src, Rect.new(x, 0, 1, 1))
    end
  end
RUBY
POSITIVE_METHODS = %w[inline local two half copy float bad guarded].freeze

NEGATIVE = <<~RUBY
  class SrNeg
    def initialize
      @bmp = Bitmap.new(8, 8)
      @src = Bitmap.new(8, 8)
    end

    def returned(x)
      r = Rect.new(x, 0, 1, 1)
      @bmp.blt(0, 0, @src, r)
      r.x
    end

    def stored(x)
      @r = Rect.new(x, 0, 1, 1)
      @bmp.blt(0, 0, @src, @r)
      @r.y
    end

    def read(x)
      r = Rect.new(x, 0, 1, 1)
      @bmp.blt(0, 0, @src, r)
      r.width
    end

    def captured(x)
      r = Rect.new(x, 0, 1, 1)
      [1].each { @bmp.blt(0, 0, @src, r) }
      :ok
    end

    def handed(x)
      keep(Rect.new(x, 0, 1, 1))
    end

    def keep(r)
      r.height
    end

    def guarded_twice(b, x)
      r = Rect.new(x, 0, 1, 1)
      b.blt(0, 0, @src, r)
      b.blt(1, 1, @src, r)
    end
  end
RUBY
NEGATIVE_METHODS = %w[returned stored read captured handed guarded_twice].freeze

# A Ruby object with a #blt: a guarded draw's else arm hands it a real Rect.
FAKE = <<~RUBY
  class FakeBmp
    def blt(x, y, src, r, *rest)
      [r.class.to_s, r.x, r.y, r.width, r.height]
    end
  end
RUBY

# The RGSS stand-in the parity run links: the classes the interpreted run calls and the entries the compiled one
# calls print the same line for one draw.
STUB = <<~CPP
  #include <mruby.h>
  #include <mruby/class.h>
  #include <mruby/data.h>
  #include <mruby/variable.h>
  #include <cstdio>
  #include "rgss_construct.hxx"
  namespace {
  struct R { mrb_int x, y, w, h; };
  const mrb_data_type rect_type = {"Rect", mrb_free};
  const mrb_data_type bmp_type = {"Bitmap", mrb_free};
  RClass* rect_class;
  RClass* bmp_class;
  int next_id;
  R& rect(mrb_state* M, mrb_value v) { return *static_cast<R*>(mrb_data_get_ptr(M, v, &rect_type)); }
  int id(mrb_state* M, mrb_value v) { return *static_cast<int*>(mrb_data_get_ptr(M, v, &bmp_type)); }
  void put(const char* what, int self, const R& r) {
    std::printf("  %s on %d rect(%ld,%ld,%ld,%ld)\\n", what, self, (long)r.x, (long)r.y, (long)r.w, (long)r.h);
  }
  void* new_rect(mrb_state* M, const R& r) {
    R* p = static_cast<R*>(mrb_malloc(M, sizeof(R)));
    *p = r;
    return p;
  }
  void* new_id(mrb_state* M) {
    int* p = static_cast<int*>(mrb_malloc(M, sizeof(int)));
    *p = ++next_id;
    return p;
  }
  R of(const rgss::RectFields& f) { return R{f.x, f.y, f.width, f.height}; }
  mrb_value make_rect(mrb_state* M, RClass* k, mrb_int x, mrb_int y, mrb_int w, mrb_int h) {
    RData* d = mrb_data_object_alloc(M, k, nullptr, &rect_type);
    d->data = new_rect(M, R{x, y, w, h});
    return mrb_obj_value(d);
  }
  mrb_value rect_init(mrb_state* M, mrb_value self) {
    mrb_int x, y, w, h;
    mrb_get_args(M, "iiii", &x, &y, &w, &h);
    DATA_TYPE(self) = &rect_type;
    DATA_PTR(self) = new_rect(M, R{x, y, w, h});
    return self;
  }
  mrb_value rect_x(mrb_state* M, mrb_value self) { return mrb_fixnum_value(rect(M, self).x); }
  mrb_value rect_y(mrb_state* M, mrb_value self) { return mrb_fixnum_value(rect(M, self).y); }
  mrb_value rect_w(mrb_state* M, mrb_value self) { return mrb_fixnum_value(rect(M, self).w); }
  mrb_value rect_h(mrb_state* M, mrb_value self) { return mrb_fixnum_value(rect(M, self).h); }
  mrb_value make_bmp(mrb_state* M, RClass* k) {
    RData* d = mrb_data_object_alloc(M, k, nullptr, &bmp_type);
    d->data = new_id(M);
    return mrb_obj_value(d);
  }
  mrb_value bmp_init(mrb_state* M, mrb_value self) {
    mrb_int w, h;
    mrb_get_args(M, "ii", &w, &h);
    DATA_TYPE(self) = &bmp_type;
    DATA_PTR(self) = new_id(M);
    return self;
  }
  mrb_value blt_m(mrb_state* M, mrb_value self) {
    mrb_int x, y, op = 255;
    mrb_value src, r;
    mrb_get_args(M, "iioo|i", &x, &y, &src, &r, &op);
    std::printf("  blt %ld %ld op %ld from %d\\n", (long)x, (long)y, (long)op, id(M, src));
    put("blt", id(M, self), rect(M, r));
    return self;
  }
  mrb_value stretch_m(mrb_state* M, mrb_value self) {
    mrb_int op = 255;
    mrb_value d, src, s;
    mrb_get_args(M, "ooo|i", &d, &src, &s, &op);
    std::printf("  stretch op %ld from %d\\n", (long)op, id(M, src));
    put("stretch dst", id(M, self), rect(M, d));
    put("stretch src", id(M, self), rect(M, s));
    return self;
  }
  mrb_value copy_m(mrb_state* M, mrb_value self) {
    mrb_int x, y;
    mrb_value src, r;
    mrb_get_args(M, "iioo", &x, &y, &src, &r);
    std::printf("  copy %ld %ld from %d\\n", (long)x, (long)y, id(M, src));
    put("copy", id(M, self), rect(M, r));
    return self;
  }
  }  // namespace
  namespace rgss {
  RClass* native_rect_class(void) { return rect_class; }
  RClass* native_bitmap_class(void) { return bmp_class; }
  mrb_value rect_new_direct(mrb_state* M, RClass* k, mrb_int x, mrb_int y, mrb_int w, mrb_int h) {
    return make_rect(M, k, x, y, w, h);
  }
  mrb_value bitmap_new_direct(mrb_state* M, RClass* k, mrb_int, mrb_int) { return make_bmp(M, k); }
  mrb_value rect_x_direct(mrb_state* M, mrb_value self) { return rect_x(M, self); }
  mrb_value rect_y_direct(mrb_state* M, mrb_value self) { return rect_y(M, self); }
  mrb_value rect_width_direct(mrb_state* M, mrb_value self) { return rect_w(M, self); }
  mrb_value rect_height_direct(mrb_state* M, mrb_value self) { return rect_h(M, self); }
  // No row reads a Bitmap's size; the guard chains of #width/#height name these.
  mrb_value bitmap_width_direct(mrb_state*, mrb_value) { return mrb_fixnum_value(0); }
  mrb_value bitmap_height_direct(mrb_state*, mrb_value) { return mrb_fixnum_value(0); }
  mrb_value bitmap_blt_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value src, mrb_value r,
                              mrb_value op, mrb_bool) {
    std::printf("  blt %ld %ld op %ld from %d\\n", (long)mrb_as_int(M, x), (long)mrb_as_int(M, y),
                (long)mrb_as_int(M, op), id(M, src));
    put("blt", id(M, self), rect(M, r));
    return self;
  }
  mrb_value bitmap_blt_rects_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value src,
                                    const RectFields& r, mrb_value op, mrb_bool) {
    std::printf("  blt %ld %ld op %ld from %d\\n", (long)mrb_as_int(M, x), (long)mrb_as_int(M, y),
                (long)mrb_as_int(M, op), id(M, src));
    put("blt", id(M, self), of(r));
    return self;
  }
  mrb_value bitmap_stretch_blt_direct(mrb_state* M, mrb_value self, mrb_value d, mrb_value src, mrb_value s,
                                      mrb_value op, mrb_bool) {
    return bitmap_stretch_blt_rects_direct(M, self, d, nullptr, src, s, nullptr, op, TRUE);
  }
  mrb_value bitmap_stretch_blt_rects_direct(mrb_state* M, mrb_value self, mrb_value d, const RectFields* df,
                                            mrb_value src, mrb_value s, const RectFields* sf, mrb_value op, mrb_bool) {
    std::printf("  stretch op %ld from %d\\n", (long)mrb_as_int(M, op), id(M, src));
    put("stretch dst", id(M, self), df ? of(*df) : rect(M, d));
    put("stretch src", id(M, self), sf ? of(*sf) : rect(M, s));
    return self;
  }
  mrb_value bitmap_copy_blt_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value src, mrb_value r) {
    std::printf("  copy %ld %ld from %d\\n", (long)mrb_as_int(M, x), (long)mrb_as_int(M, y), id(M, src));
    put("copy", id(M, self), rect(M, r));
    return self;
  }
  mrb_value bitmap_copy_blt_rects_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value src,
                                         const RectFields& r) {
    std::printf("  copy %ld %ld from %d\\n", (long)mrb_as_int(M, x), (long)mrb_as_int(M, y), id(M, src));
    put("copy", id(M, self), of(r));
    return self;
  }
  }  // namespace rgss
  void stack_rect_stub_init(mrb_state* M) {
    RClass* m = mrb_define_module(M, "RGSS");
    rect_class = mrb_define_class_under(M, m, "Rect", M->object_class);
    MRB_SET_INSTANCE_TT(rect_class, MRB_TT_DATA);
    mrb_define_method(M, rect_class, "initialize", rect_init, MRB_ARGS_REQ(4));
    mrb_define_method(M, rect_class, "x", rect_x, MRB_ARGS_NONE());
    mrb_define_method(M, rect_class, "y", rect_y, MRB_ARGS_NONE());
    mrb_define_method(M, rect_class, "width", rect_w, MRB_ARGS_NONE());
    mrb_define_method(M, rect_class, "height", rect_h, MRB_ARGS_NONE());
    bmp_class = mrb_define_class_under(M, m, "Bitmap", M->object_class);
    MRB_SET_INSTANCE_TT(bmp_class, MRB_TT_DATA);
    mrb_define_method(M, bmp_class, "initialize", bmp_init, MRB_ARGS_REQ(2));
    mrb_define_method(M, bmp_class, "blt", blt_m, MRB_ARGS_ARG(4, 1));
    mrb_define_method(M, bmp_class, "stretch_blt", stretch_m, MRB_ARGS_ARG(3, 1));
    mrb_define_method(M, bmp_class, "copy_blt", copy_m, MRB_ARGS_REQ(4));
    mrb_define_const(M, M->object_class, "Rect", mrb_obj_value(rect_class));
    mrb_define_const(M, M->object_class, "Bitmap", mrb_obj_value(bmp_class));
    next_id = 0;
  }
CPP

# The generated body of +klass+#+meth+ (its _impl functions).
def body_of(code, klass, meth)
  code.scan(/^(?:static )?(?:inline )?mrb_value #{klass}_#{meth}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?(?:inline )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate(source, owners, off: false)
  saved = ENV.fetch('BC2CPP_STACK_RECT', nil)
  ENV['BC2CPP_STACK_RECT'] = '0' if off
  Dir.mktmpdir('stack-rect') do |dir|
    code, err = Bc2cppFixtureRuntime.generate(source, dir, only_owners: owners)
    yield code, err, dir
  end
ensure
  saved.nil? ? ENV.delete('BC2CPP_STACK_RECT') : ENV['BC2CPP_STACK_RECT'] = saved
end

unless ENV['MRBC']
  puts '-- SKIP placement and parity: set MRBC'
  abort "FAILED: #{failures.join(', ')}" unless failures.empty?
  puts 'bc2cpp stack rect check: PASS'
  exit
end

ROWS = [
  *%w[inline local two copy float].map { |m| "SrPos.new.#{m}(3)" }, 'SrPos.new.bad(3, :no)', 'SrPos.new.bad(3, 4)',
  'SrPos.new.half(2, Rect.new(4, 5, 6, 7))',
  'SrPos.new.guarded(Bitmap.new(2, 2), 5).class', 'SrPos.new.guarded(FakeBmp.new, 5)',
  *%w[returned stored read captured handed].map { |m| "SrNeg.new.#{m}(4)" },
  'SrNeg.new.guarded_twice(FakeBmp.new, 6)', 'SrNeg.new.guarded_twice(Bitmap.new(1, 1), 6).class'
].freeze

scenario = <<~CPP
  void stack_rect_stub_init(mrb_state* M);
  static int scenario(mrb_state* M) {
    stack_rect_stub_init(M);
    const char* rows[] = {
  #{ROWS.map { |row| "    #{row.inspect}," }.join("\n")}
    };
    for (const char* src : rows) {
      std::printf("%s\\n", src);
      mrb_value v = mrb_load_string(M, src);
      if (M->exc) { show_exc(M, src); continue; }
      show(M, src, v);
    }
    return 0;
  }
CPP

source = POSITIVE + NEGATIVE + FAKE
owners = %w[SrPos SrNeg]
puts '== placement'
off_code = nil
generate(source, owners, off: true) { |code, _err, _dir| off_code = code }
check.call('kill switch: BC2CPP_STACK_RECT=0 places no fields', !off_code.include?('bc2cpp_srect') &&
                                                                 !off_code.include?('_rects_direct'))
generate(source, owners) do |code, err, dir|
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'stack_rect.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  if world_has_entries
    POSITIVE_METHODS.each do |meth|
      body = body_of(code, 'SrPos', meth)
      site_free = body.scan(/r\d+ = rgss::rect_new_direct\(M, rgss::native_rect_class\(\), bc2cpp_pu/).empty?
      check.call("#{meth}: the Rect stays as its fields, the draw takes them",
                 body.include?('bc2cpp_srect') && body.include?('_rects_direct(') && site_free)
    end
    guarded = body_of(code, 'SrPos', 'guarded')
    check.call('guarded: the Rect is made only in the dispatch arm',
               guarded.match?(/\} else \{\n\s*r\d+ = rgss::rect_new_direct\(M, rgss::native_rect_class\(\), bc2cpp_srect\d+\.x/))
    NEGATIVE_METHODS.each do |meth|
      body = body_of(code, 'SrNeg', meth)
      check.call("#{meth}: keeps its Rect, as with BC2CPP_STACK_RECT=0",
                 !body.empty? && !body.include?('bc2cpp_srect') && body == body_of(off_code, 'SrNeg', meth))
    end
  else
    check.call('an older world places no fields', !code.include?('bc2cpp_srect'))
    puts '  SKIP placement: the world declares no RectFields entries'
  end

  puts '== parity, interpreted against compiled'
  build = runtime.full_or_build
  if !world_has_entries
    puts '  SKIP run: the world declares no RectFields entries'
  elsif build
    stub = File.join(dir, 'rgss_stub.cpp')
    File.write(stub, STUB)
    built, output = runtime.run(dir, err, owners, scenario, build: build, full: true, extra_srcs: [stub])
    sections = runtime.sections(output)
    check.call('built and ran', built)
    check.call('every draw takes the same rect in both runs',
               !sections['compiled'].to_a.empty? && sections['compiled'] == sections['interpreted'])
    check.call('a guarded draw hands a Ruby #blt a real Rect',
               sections['compiled'].to_a.include?('SrPos.new.guarded(FakeBmp.new, 5) => ["RGSS::Rect", 5, 0, 1, 1]'))
    check.call('a non-Integer field raises TypeError as Rect.new does',
               sections['compiled'].to_a.include?('SrPos.new.bad(3, :no) => raised TypeError'))
    warn output unless failures.empty?
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp stack rect check: PASS'
