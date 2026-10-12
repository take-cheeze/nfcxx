#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check DIRECT_RAISE (docs/adr/0226): a reviewed dead fallback calls
# bc2cpp_nomethod_raise, which must raise the NoMethodError that the dispatching
# bc2cpp_nomethod raises when no method answers the name: the same class,
# message, name, args and backtrace.
#
#   - NomethodReviewed.direct_raise renames a listed site's call and nothing else;
#   - against a real mruby core, both helpers raise the same error for a set of
#     receiver kinds (the cfunc names are normalised, since they show in the backtrace);
#   - the raise helper carries the verify switch, and -DBC2CPP_NOMETHOD_VERIFY
#     aborts naming the site before any raise.
#
#   MRBC=path/to/host/mrbc BC2CPP_MRUBY_CORE=dir ruby scripts/bc2cpp/nomethod_raise_check.rb
#   (dir: lib/libmruby.a or lib/libmruby_core.a, and include/)

require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/symbol_cache'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- the rename -------------------------------------------------------------------

puts '== NomethodReviewed.direct_raise (the callee rename)'
owner = 'Game::Battle'
method = 'advance_gauges'
listed = 'r5 = bc2cpp_nomethod_named(M, r2, "hidden"); /* CLOSED_WORLD nomethod: recv.hidden */'
listed_args = 'r6 = bc2cpp_nomethod_named(M, r1, "gauge=", 1, r3); /* CLOSED_WORLD nomethod: self.gauge= */'
unlisted = 'r7 = bc2cpp_nomethod_named(M, r2, "not_reviewed"); /* CLOSED_WORLD nomethod: recv.not_reviewed */'
check.call('a listed site (no args) is renamed, marker kept',
           NomethodReviewed.direct_raise(listed, owner, method) ==
             'r5 = bc2cpp_nomethod_raise_named(M, r2, "hidden"); /* CLOSED_WORLD nomethod: recv.hidden */')
check.call('a listed site with args is renamed, args kept',
           NomethodReviewed.direct_raise(listed_args, owner, method) ==
             'r6 = bc2cpp_nomethod_raise_named(M, r1, "gauge=", 1, r3); /* CLOSED_WORLD nomethod: self.gauge= */')
check.call('an unlisted site keeps the dispatching fallback',
           NomethodReviewed.direct_raise(unlisted, owner, method) == unlisted)
check.call('the same name in another method is not the listed key',
           NomethodReviewed.direct_raise(listed, owner, 'no_such_method') == listed)
check.call('code without a marker is untouched',
           NomethodReviewed.direct_raise('r1 = bc2cpp_nomethod_named(M, r2, "hidden");', owner, method) ==
             'r1 = bc2cpp_nomethod_named(M, r2, "hidden");')

# -- the helper against a real mruby core -----------------------------------------

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural check: no mruby core with lib/ and include/ found (set BC2CPP_MRUBY_CORE)'
else
  puts '== the raise against a real mruby core, the same NoMethodError as dispatch'
  # The probe is Ruby, compiled to bytecode by the same mrbc the build uses and loaded with mrb_load_irep.
  full_lib = [File.join(core, 'lib/libmruby.a'), File.join(core, 'lib/libmruby_core.a')].find { |p| File.exist?(p) }
  table = SymbolCache::Table.new
  table.index_for('"gone"')
  table.nomethod_used = true
  cache = SymbolCache.emit(table)
  probe = <<~'RUBY'
    $out = ''
    # Direct calls, not send: this core has no Kernel#send, which would raise before the cfunc ran.
    def call(form, recv)
      case form
      when :old0 then recv.old0
      when :new0 then recv.new0
      when :old2 then recv.old2(1, 2)
      when :new2 then recv.new2(1, 2)
      end
    end
    def probe(form, recv)
      call(form, recv)
      $out += "NORAISE #{form}\n"
    rescue Exception => e
      name = begin; e.name.inspect; rescue Exception; 'n/a'; end
      args = begin; e.args.inspect; rescue Exception; 'n/a'; end
      $out += [form, e.class.to_s, e.message, name, args, e.backtrace].inspect + "\n"
    end
    # Each receiver: the dispatching form then the raise form, arity 0 and 2. A verify build runs the raise form only,
    # so its abort names the raise helper's site and not the dispatching one's.
    [Object.new, nil, 1, :sym, 'str', Object, [1, 2]].each do |recv|
      if $raise_only
        probe(:new0, recv)
        probe(:new2, recv)
      else
        probe(:old0, recv)
        probe(:new0, recv)
        probe(:old2, recv)
        probe(:new2, recv)
      end
    end
  RUBY
  source = <<~CPP
    #include <mruby.h>
    #include <mruby/array.h>
    #include <mruby/class.h>
    #include <mruby/error.h>
    #include <mruby/irep.h>
    #include <mruby/string.h>
    #include <mruby/variable.h>
    #include <cstdarg>
    #include <cstdio>
    #include <string>

    static mrb_value bc2cpp_funcall_argv(mrb_state* M, mrb_value r, mrb_sym m, mrb_int n, const mrb_value* a) { return mrb_funcall_argv(M, r, m, n, a); }

    #{cache}

    extern const uint8_t probe_irep[];

    static mrb_value old0(mrb_state* M, mrb_value self) { return bc2cpp_nomethod(M, self, 0); }
    static mrb_value new0(mrb_state* M, mrb_value self) { return bc2cpp_nomethod_raise(M, self, 0); }
    static mrb_value old2(mrb_state* M, mrb_value self) {
      mrb_value a[2];
      mrb_get_args(M, "oo", &a[0], &a[1]);
      return bc2cpp_nomethod(M, self, 0, 2, a[0], a[1]);
    }
    static mrb_value new2(mrb_state* M, mrb_value self) {
      mrb_value a[2];
      mrb_get_args(M, "oo", &a[0], &a[1]);
      return bc2cpp_nomethod_raise(M, self, 0, 2, a[0], a[1]);
    }

    int main(int argc, char** argv) {
      mrb_state* M = mrb_open_core();
      mrb_define_method(M, M->object_class, "old0", old0, MRB_ARGS_NONE());
      mrb_define_method(M, M->object_class, "new0", new0, MRB_ARGS_NONE());
      mrb_define_method(M, M->object_class, "old2", old2, MRB_ARGS_REQ(2));
      mrb_define_method(M, M->object_class, "new2", new2, MRB_ARGS_REQ(2));
      mrb_gv_set(M, mrb_intern_cstr(M, "$raise_only"), mrb_bool_value(argc > 1 && std::string(argv[1]) == "raise"));
      mrb_load_irep(M, probe_irep);
      mrb_value out = mrb_gv_get(M, mrb_intern_cstr(M, "$out"));
      std::fputs(mrb_str_to_cstr(M, out), stdout);
      mrb_close(M);
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    probe_rb = File.join(dir, 'probe.rb')
    File.write(probe_rb, probe)
    irep_c = File.join(dir, 'probe_irep.c')
    compiled_irep = system(mrbc, '-Bprobe_irep', '-o', irep_c, probe_rb)
    source_path = File.join(dir, 'raise_probe.cpp')
    File.write(source_path, source)
    build = lambda do |name, *flags|
      binary = File.join(dir, name)
      ok = compiled_irep && Bc2cppCxx.system('-std=gnu++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', *flags,
                                             "-I#{core}/include", "-I#{root}/3rd/mruby/include", source_path, irep_c,
                                             full_lib, '-lm', '-o', binary)
      ok ? binary : nil
    end
    normal = build.call('normal')
    verify = build.call('verify', '-DBC2CPP_NOMETHOD_VERIFY')
    check.call('the probe builds with and without -DBC2CPP_NOMETHOD_VERIFY', !normal.nil? && !verify.nil?)
    if normal
      out, status = Open3.capture2e(normal)
      lines = out.lines
      # 7 receivers, each giving old0, new0, old2, new2 in that order: 28 lines, paired (old, new) by arity.
      check.call('the probe runs to completion, one line per call (28)', status.success? && lines.size == 28)
      check.call('every call raises a NoMethodError (none returns, none raises another class)',
                 lines.all? { |l| l.include?('"NoMethodError"') })
      # The probe must reach the dead site: every message names the missing method "gone", not a call of the probe.
      check.call("every message is \"undefined method 'gone'\" (the probe reached the site)",
                 lines.all? { |l| l.include?("undefined method 'gone' for ") })
      # The cfunc names differ (old/new) and show in the backtrace; they are the only thing normalised.
      normalise = ->(line) { line.gsub(/(old|new)([02])/, 'X\2') }
      pairs = lines.each_slice(2).to_a
      mismatch = pairs.reject { |old, new| normalise.call(old) == normalise.call(new) }
      check.call("both forms raise the same class, message, name, args and backtrace (#{pairs.size} pairs)",
                 mismatch.empty?)
      mismatch.first(3).each { |old, new| puts "    old: #{old.strip}\n    new: #{new.strip}" }
      puts "    sample: #{lines.first.strip}" if lines.first
    end
    if verify
      out, status = Open3.capture2e(verify, 'raise')
      check.call('verify mode aborts at the raise site, naming the class and method, before raising',
                 status.signaled? && status.termsig == Signal.list.fetch('ABRT') &&
                   out.include?('bc2cpp: NOMETHOD_VERIFY: dead site reached: Object#gone (0 arg(s))'))
    end
  end
end

check.call('the raise helper carries the verify switch, off unless defined',
           SymbolCache.emit(SymbolCache::Table.new.tap { |t| t.nomethod_used = true })
             .then { |text| text.include?('bc2cpp_nomethod_raise_argv') && text.include?('#ifdef BC2CPP_NOMETHOD_VERIFY') })

if failures.empty?
  puts 'bc2cpp_nomethod_raise_check: ok'
else
  abort "bc2cpp_nomethod_raise_check: #{failures.size} failure(s)"
end
