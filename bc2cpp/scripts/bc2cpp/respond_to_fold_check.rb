#!/usr/bin/env ruby
# frozen_string_literal: true

# Check RESPOND_TO_FOLD (tools/bc2cpp/codegen_respond_to_fold.rb) on closed-world fixtures:
#   1. generated code: a receiver of a known class folds to a constant (true for a Ruby `def`, a private one included,
#      false for a class no definition reaches); an unknown receiver of a name only Ruby classes define folds to their
#      membership test; a name nothing defines folds to false; a world with a respond_to_missing? folds nothing;
#   2. run on a full-core mruby, compiled against interpreted: every answer is the same, for instances of the
#      defining class, its subclass, another class, nil and an Integer.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/respond_to_fold_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class Rev
    def initialize; @r = 3; end
    def revision; @r; end

    private

    def secret; 1; end
  end
  class Kid < Rev
  end
  class Plain
    def initialize; @x = 0; end
  end
  class Probe
    def rev?(o); o.respond_to?(:revision); end
    def nope?(o); o.respond_to?(:rtf_nothing_defines_this); end
    def known; Rev.new.respond_to?(:revision); end
    def known_no; Plain.new.respond_to?(:revision); end
    def priv; Rev.new.respond_to?(:secret); end
  end
RUBY
OWNERS = %w[Rev Kid Plain Probe].freeze

# The same probe where a class answers through respond_to_missing?: no fold may stand.
MISSING_SOURCE = <<~RUBY
  class Rev
    def initialize; @r = 3; end
    def revision; @r; end
  end
  class Ghost
    def initialize; @g = 0; end
    def respond_to_missing?(name, priv = false); name == :revision; end
  end
  class Probe
    def rev?(o); o.respond_to?(:revision); end
  end
RUBY
MISSING_OWNERS = %w[Rev Ghost Probe].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{Regexp.escape(name.sub('?', '$3f'))}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
fold = ->(text) { text[%r{// RESPOND_TO_FOLD :\S+ -- [^\n]*\n#ifdef BC2CPP_UNREGISTERED_VERIFY\n.*?#else\n(.*?)\n#endif}m, 1].to_s.strip }

HARNESS = <<~'CPP'
  #include <mruby/error.h>
  #include <string>
  struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[1]; };
  static mrb_value call_body(mrb_state* M, void* ud) {
    Call* c = (Call*)ud;
    return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
  }
  static void row(mrb_state* M, const char* label, const char* meth, mrb_int argc, mrb_value recv) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    Call c = { probe, mrb_intern_cstr(M, meth), argc, { recv } };
    mrb_bool raised = FALSE;
    mrb_value v = mrb_protect_error(M, call_body, &c, &raised);
    mrb_value s = raised ? mrb_funcall(M, v, "message", 0) : mrb_inspect(M, v);
    std::printf("%s => %s%s\n", label, raised ? "raised " : "", std::string(RSTRING_PTR(s), RSTRING_LEN(s)).c_str());
  }
  static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
CPP

SCENARIO = <<~'CPP'
  static int scenario(mrb_state* M) {
    row(M, "rev.revision", "rev?", 1, eval(M, "Rev.new"));
    row(M, "kid.revision", "rev?", 1, eval(M, "Kid.new"));
    row(M, "plain.revision", "rev?", 1, eval(M, "Plain.new"));
    row(M, "nil.revision", "rev?", 1, mrb_nil_value());
    row(M, "int.revision", "rev?", 1, mrb_int_value(M, 1));
    row(M, "rev.nothing", "nope?", 1, eval(M, "Rev.new"));
    row(M, "nil.nothing", "nope?", 1, mrb_nil_value());
    row(M, "known", "known", 0, mrb_nil_value());
    row(M, "known_no", "known_no", 0, mrb_nil_value());
    row(M, "private", "priv", 0, mrb_nil_value());
    return 0;
  }
CPP

MISSING_SCENARIO = <<~'CPP'
  static int scenario(mrb_state* M) {
    row(M, "rev.revision", "rev?", 1, eval(M, "Rev.new"));
    row(M, "ghost.revision", "rev?", 1, eval(M, "Ghost.new"));
    row(M, "nil.revision", "rev?", 1, mrb_nil_value());
    return 0;
  }
CPP

def parity(runtime, dir, err, owners, harness, check, failures, label)
  build = runtime.full_or_build
  unless build
    puts '  SKIP run: no full-core mruby build'
    return []
  end
  built, output = runtime.run(dir, err, owners, harness, build: build, full: true)
  sections = runtime.sections(output)
  compiled = sections['compiled'].to_a
  interpreted = sections['interpreted'].to_a
  check.call("#{label}: built and ran", built)
  check.call("#{label}: runtime parity (every row)", !compiled.empty? && compiled == interpreted)
  warn output unless failures.empty?
  compiled
end

Dir.mktmpdir('respond-to-fold') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'respond_to_fold.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  check.call('known: a Rev receiver folds to true', fold.call(body.call(code, 'known')).end_with?('mrb_bool_value(true);'))
  check.call('known_no: a Plain receiver folds to false', fold.call(body.call(code, 'known_no')).end_with?('mrb_bool_value(false);'))
  check.call('priv: a private def still answers (mruby ignores visibility)', fold.call(body.call(code, 'priv')).end_with?('mrb_bool_value(true);'))
  rev = fold.call(body.call(code, 'rev?'))
  check.call('rev?: an unknown receiver folds to membership in Rev and Kid', rev.include?('bc2cpp_class_is') && rev.scan('bc2cpp_class_is').size == 2)
  check.call('nope?: a name nothing defines folds to false', fold.call(body.call(code, 'nope?')).end_with?('mrb_bool_value(false);'))
  folded = %w[rev? nope? known known_no priv].all? { |m| !body.call(code, m).split('#else').last.to_s.split('#endif').first.to_s.include?('bc2cpp_owner_call') }
  check.call('no folded site keeps a respond_to? call outside the verify branch', folded)

  unless ENV['CC_GENERATED_ONLY'] == '1'
    compiled = parity(runtime, dir, err, OWNERS, HARNESS + SCENARIO, check, failures, 'fold')
    unless compiled.empty?
      check.call('a subclass answers true', compiled.include?('kid.revision => true'))
      check.call('an unrelated class, nil and an Integer answer false',
                 %w[plain.revision nil.revision int.revision].all? { |l| compiled.include?("#{l} => false") })
    end
  end
end

Dir.mktmpdir('respond-to-fold-missing') do |dir|
  code, err = runtime.generate(MISSING_SOURCE, dir, only_owners: MISSING_OWNERS)
  check.call('respond_to_missing?: nothing folds', !code.include?('RESPOND_TO_FOLD'))
  unless ENV['CC_GENERATED_ONLY'] == '1'
    compiled = parity(runtime, dir, err, MISSING_OWNERS, HARNESS + MISSING_SCENARIO, check, failures, 'respond_to_missing?')
    check.call('Ghost answers through respond_to_missing?', compiled.include?('ghost.revision => true')) unless compiled.empty?
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp respond_to fold check: PASS'
