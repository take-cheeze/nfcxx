#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour oracle for persistent frozen string literals: a `# frozen_string_literal: true` literal is
# the VM's one persistent frozen String for its bytes, in interpreted and bc2cpp-compiled code alike.
#
#   1. run (full-core mruby), interpreted against compiled: the magic-comment class answers the same on both sides
#      and each value matches the value written here: identity across calls, frozen?, text, FrozenError on mutation,
#      interpolated and dup'd strings unfrozen, %w elements frozen, identity and content after mrb_full_gc.
#   2. run: a file without the magic comment keeps the old fresh, unfrozen String, interpreted and compiled.
#   3. a C++ driver opens two VMs in one process: each VM gets its own object, interleaved calls and collections keep
#      it, a VM opened after another closed (possibly at its address) gets its own, and teardown does not crash.
#   4. generation: BC2CPP_FROZEN_LITERALS=0 emits the old mrb_str_new_cstr path, and a file without the magic
#      comment generates the same code with or without the switch.
#
# Usage: MRBC=path/to/host/mrbc BC2CPP_MRUBY_FULL=path/to/host/build ruby scripts/bc2cpp/frozen_literal_persist_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative 'cxx'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

MAGIC = <<~'RUBY'
  # frozen_string_literal: true

  class Lit
    def word
      "abc"
    end

    def same
      a = word
      b = word
      a.equal?(b)
    end

    def mutate
      begin
        word << "x"
        "no error"
      rescue FrozenError
        "FrozenError"
      end
    end

    def interpolated
      "a#{word}".frozen?
    end

    def dup_frozen
      word.dup.frozen?
    end

    def words
      %w[p q][0].frozen?
    end
  end
RUBY

PLAIN = <<~'RUBY'
  class Plain
    def word
      "abc"
    end

    def same
      a = word
      b = word
      a.equal?(b)
    end

    def mutate
      s = word
      s << "x"
      s
    end
  end
RUBY

# The C++ rows both sides print: every label and the value the interpreter prints for it.
MAGIC_EXPECTED = {
  'Lit#same' => 'true',
  'Lit#word' => '"abc"',
  'Lit#word frozen?' => 'true',
  'Lit#word identity' => 'true',
  'Lit#mutate' => '"FrozenError"',
  'Lit#interpolated' => 'false',
  'Lit#dup_frozen' => 'false',
  'Lit#words' => 'true',
  'Lit#word after gc' => '"abc"',
  'Lit#word identity after gc' => 'true',
  'Lit#word identity under stress' => 'true',
}.freeze
PLAIN_EXPECTED = {
  'Plain#same' => 'false',
  'Plain#word' => '"abc"',
  'Plain#word frozen?' => 'false',
  'Plain#mutate' => '"abcx"',
}.freeze

# The C++ driver: one probe per row, shown through the same show() the other harnesses use. It calls the methods
# with mrb_funcall, so the value comes from whichever body the VM runs (interpreted or compiled).
PROBE_BODY = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "Lit"), 0, nullptr);
    mrb_value w1 = send0(M, "Lit#word", obj, "word");
    mrb_value w2 = mrb_funcall(M, obj, "word", 0);
    std::printf("Lit#word identity => %s\\n", mrb_ptr(w1) == mrb_ptr(w2) ? "true" : "false");
    send0(M, "Lit#word frozen?", w1, "frozen?");
    send0(M, "Lit#same", obj, "same");
    send0(M, "Lit#mutate", obj, "mutate");
    send0(M, "Lit#interpolated", obj, "interpolated");
    send0(M, "Lit#dup_frozen", obj, "dup_frozen");
    send0(M, "Lit#words", obj, "words");
    mrb_full_gc(M);
    mrb_value w3 = send0(M, "Lit#word after gc", obj, "word");
    std::printf("Lit#word identity after gc => %s\\n", mrb_ptr(w3) == mrb_ptr(w1) ? "true" : "false");
    bool stable = true;
    for (int i = 0; i < 300; ++i) {
      if (mrb_ptr(mrb_funcall(M, obj, "word", 0)) != mrb_ptr(w1)) stable = false;
      mrb_funcall(M, obj, "same", 0);
      if (i % 50 == 0) mrb_full_gc(M);
    }
    std::printf("Lit#word identity under stress => %s\\n", stable ? "true" : "false");
    return 0;
  }
CPP

PLAIN_PROBE_BODY = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "Plain"), 0, nullptr);
    send0(M, "Plain#word", obj, "word");
    mrb_value w1 = mrb_funcall(M, obj, "word", 0);
    send0(M, "Plain#word frozen?", w1, "frozen?");
    send0(M, "Plain#same", obj, "same");
    send0(M, "Plain#mutate", obj, "mutate");
    return 0;
  }
CPP

# The shared helper the probes use: prints "label => value" (or the exception class) and returns the value.
PROBE_HELPER = <<~CPP
  static mrb_value send0(mrb_state* M, const char* label, mrb_value obj, const char* meth) {
    mrb_value r = mrb_funcall(M, obj, meth, 0);
    if (M->exc) {
      show_exc(M, label);
      return mrb_nil_value();
    }
    show(M, label, r);
    return r;
  }
CPP

# The C++ driver for check 3, built against the same full-core libmruby as the bc2cpp runs.
TWO_VM_DRIVER = <<~CPP
  #include <mruby.h>
  #include <mruby/irep.h>
  #include <mruby/string.h>
  #include <mruby/class.h>
  #include <mruby/error.h>
  #include <cstdio>
  #include <cstring>
  #include <fstream>
  #include <iterator>
  #include <vector>

  static mrb_value word(mrb_state* M, mrb_value self) { return mrb_funcall(M, self, "word", 0); }
  static bool same_object(mrb_value a, mrb_value b) { return mrb_ptr(a) == mrb_ptr(b); }
  static bool is_abc(mrb_value v) { return RSTRING_LEN(v) == 3 && std::memcmp(RSTRING_PTR(v), "abc", 3) == 0; }
  static const char* mutation_class(mrb_state* M, mrb_value s) {
    mrb_funcall(M, s, "<<", 1, mrb_str_new_cstr(M, "x"));
    if (!M->exc) return "none";
    mrb_value e = mrb_obj_value(M->exc);
    M->exc = nullptr;
    return mrb_obj_classname(M, e);
  }
  static mrb_value set_persistent_body(mrb_state* M, mrb_value v) {
    mrb_obj_set_persistent(M, v);
    return mrb_nil_value();
  }
  static mrb_state* open_vm(const std::vector<uint8_t>& bin) {
    mrb_state* M = mrb_open();
    mrb_load_irep_buf(M, bin.data(), bin.size());
    return M;
  }

  int main(int, char** argv) {
    std::ifstream in(argv[1], std::ios::binary);
    std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    mrb_state* A = open_vm(bin);
    mrb_state* B = open_vm(bin);
    if (A->exc || B->exc) return 2;
    mrb_value oa = mrb_obj_new(A, mrb_class_get(A, "Lit"), 0, nullptr);
    mrb_value ob = mrb_obj_new(B, mrb_class_get(B, "Lit"), 0, nullptr);
    mrb_value wa = word(A, oa);
    mrb_value wb = word(B, ob);
    std::printf("two VMs distinct => %s\\n", mrb_ptr(wa) != mrb_ptr(wb) ? "true" : "false");
    bool ida = true, idb = true;
    for (int i = 0; i < 400; ++i) {
      if (!same_object(word(A, oa), wa)) ida = false;
      if (!same_object(word(B, ob), wb)) idb = false;
      if (i % 50 == 0) {
        mrb_full_gc(A);
        mrb_full_gc(B);
      }
    }
    std::printf("VM A identity under interleaving => %s\\n", ida ? "true" : "false");
    std::printf("VM B identity under interleaving => %s\\n", idb ? "true" : "false");
    std::printf("VM A mutation => %s\\n", mutation_class(A, wa));
    std::printf("VM B mutation => %s\\n", mutation_class(B, wb));
    // The flag itself, without the literal table: an unrooted persistent String survives a collection, and
    // the setter refuses an unfrozen String and a singleton class.
    int ai = mrb_gc_arena_save(A);
    mrb_value keep = mrb_str_new_cstr(A, "keep");
    mrb_obj_freeze(A, keep);
    mrb_obj_set_persistent(A, keep);
    struct RBasic* kp = mrb_basic_ptr(keep);
    mrb_gc_arena_restore(A, ai);
    mrb_full_gc(A);
    bool kept = !mrb_object_dead_p(A, kp) && RSTRING_LEN(keep) == 4 && std::memcmp(RSTRING_PTR(keep), "keep", 4) == 0;
    std::printf("persistent String survives unrooted collection => %s\\n", kept ? "true" : "false");
    mrb_value unfrozen = mrb_str_new_cstr(A, "x");
    mrb_bool refused = FALSE;
    mrb_value err = mrb_protect(A, set_persistent_body, unfrozen, &refused);
    std::printf("setter refuses an unfrozen String => %s\\n", refused ? mrb_obj_classname(A, err) : "none");
    A->exc = nullptr;
    mrb_funcall(A, wa, "singleton_class", 0);
    std::printf("persistent String refuses a singleton class => %s\\n", A->exc ? mrb_obj_classname(A, mrb_obj_value(A->exc)) : "none");
    A->exc = nullptr;
    mrb_close(A);
    mrb_full_gc(B);
    std::printf("VM B after close of A => %s\\n", same_object(word(B, ob), wb) && is_abc(wb) ? "true" : "false");
    mrb_state* C = open_vm(bin);
    mrb_value oc = mrb_obj_new(C, mrb_class_get(C, "Lit"), 0, nullptr);
    mrb_value wc = word(C, oc);
    std::printf("VM C content => %s\\n", is_abc(wc) ? "true" : "false");
    std::printf("VM C identity => %s\\n", same_object(word(C, oc), wc) ? "true" : "false");
    mrb_full_gc(C);
    std::printf("VM C after gc => %s\\n", is_abc(wc) && same_object(word(C, oc), wc) ? "true" : "false");
    mrb_close(B);
    mrb_close(C);
    std::printf("teardown => ok\\n");
    (void)argv;
    return 0;
  }
CPP

TWO_VM_EXPECTED = [
  'two VMs distinct => true',
  'VM A identity under interleaving => true',
  'VM B identity under interleaving => true',
  'VM A mutation => FrozenError',
  'VM B mutation => FrozenError',
  'persistent String survives unrooted collection => true',
  'setter refuses an unfrozen String => ArgumentError',
  'persistent String refuses a singleton class => FrozenError',
  'VM B after close of A => true',
  'VM C content => true',
  'VM C identity => true',
  'VM C after gc => true',
  'teardown => ok',
].freeze

# The probes' prelude: the run() prelude already defines show() and show_exc(); send0 is the probes' own helper.
def harness_for(body)
  "#{PROBE_HELPER}\n#{body}"
end

Dir.mktmpdir('frozen-literal-persist') do |dir|
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : runtime.full_or_build

  # 1. magic comment, interpreted against compiled
  magic_dir = File.join(dir, 'magic')
  FileUtils.mkdir_p(magic_dir)
  code, err = runtime.generate(MAGIC, magic_dir, only_owners: %w[Lit])
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'frozen_literal_persist.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  check.call('magic fixture generates a frozen-literal site', code.include?('mrb_frozen_literal(M, '))

  if build
    built, output = runtime.run(magic_dir, err, %w[Lit], harness_for(PROBE_BODY), build: build, full: true)
    sections = runtime.sections(output)
    check.call('magic: built and ran', built)
    check.call('magic: runtime parity, interpreted against compiled',
               !sections['compiled'].to_a.empty? && sections['compiled'] == sections['interpreted'])
    MAGIC_EXPECTED.each do |label, value|
      check.call("magic: #{label} => #{value}", sections['compiled'].to_a.include?("#{label} => #{value}"))
    end
    warn output unless failures.empty?
  else
    puts '  SKIP magic run: no full-core mruby build'
  end

  # 2. no magic comment: the old fresh, unfrozen String, interpreted and compiled
  plain_dir = File.join(dir, 'plain')
  FileUtils.mkdir_p(plain_dir)
  plain_code, plain_err = runtime.generate(PLAIN, plain_dir, only_owners: %w[Plain])
  check.call('plain fixture generates no frozen-literal site', !plain_code.include?('mrb_frozen_literal'))
  if build
    built, output = runtime.run(plain_dir, plain_err, %w[Plain], harness_for(PLAIN_PROBE_BODY), build: build, full: true)
    sections = runtime.sections(output)
    check.call('plain: built and ran', built)
    check.call('plain: runtime parity, interpreted against compiled',
               !sections['compiled'].to_a.empty? && sections['compiled'] == sections['interpreted'])
    PLAIN_EXPECTED.each do |label, value|
      check.call("plain: #{label} => #{value}", sections['compiled'].to_a.include?("#{label} => #{value}"))
    end
  end

  # 3. two VMs in one process (C++ driver over the interpreted bytecode of the magic fixture)
  if build
    driver = File.join(magic_dir, 'two_vm.cpp')
    File.write(driver, TWO_VM_DRIVER)
    binary = File.join(magic_dir, 'two_vm')
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w]
    flags.concat(Shellwords.split(ENV.fetch('BC2CPP_CXXFLAGS', '')))
    compiled = Bc2cppCxx.system(*flags, "-I#{build}/include", "-I#{Bc2cppFixtureRuntime::ROOT}/3rd/mruby/include",
                                driver, "#{build}/lib/libmruby.a", '-lm', '-o', binary)
    check.call('two VMs: driver built', compiled)
    if compiled
      output = IO.popen([binary, File.join(magic_dir, 'fixture.mrb')], err: %i[child out], &:read)
      check.call('two VMs: driver exited cleanly', $?.success?)
      TWO_VM_EXPECTED.each do |row|
        check.call("two VMs: #{row}", output.lines.map(&:chomp).include?(row))
      end
    end
  end

  # 4. the kill switch: the magic file generates the old path, and a file without the magic is unchanged by it
  begin
    previous = ENV.fetch('BC2CPP_FROZEN_LITERALS', nil)
    ENV['BC2CPP_FROZEN_LITERALS'] = '0'
    off_dir = File.join(dir, 'off')
    FileUtils.mkdir_p(off_dir)
    off_code, = runtime.generate(MAGIC, off_dir, only_owners: %w[Lit])
    plain_off_dir = File.join(dir, 'plain_off')
    FileUtils.mkdir_p(plain_off_dir)
    plain_off_code, = runtime.generate(PLAIN, plain_off_dir, only_owners: %w[Plain])
  ensure
    ENV['BC2CPP_FROZEN_LITERALS'] = previous
  end
  check.call('kill switch: magic file emits no mrb_frozen_literal', !off_code.include?('mrb_frozen_literal'))
  check.call('kill switch: magic file emits the old mrb_str_new_cstr site',
             off_code.include?('mrb_str_new_cstr(M, "\\x61\\x62\\x63")'))
  check.call('kill switch: a file without the magic generates the same code', plain_off_code == plain_code)
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp frozen literal persist check: PASS'
