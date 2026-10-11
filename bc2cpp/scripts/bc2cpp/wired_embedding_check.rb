#!/usr/bin/env ruby
# encoding: UTF-8
# Check BC2CPP_WIRED_EMBEDDINGS (tools/bc2cpp/compiled_gems.rb): a class whose
# ivars are embedded in an RData struct is only sound when EVERY compiled entry
# point of that class is installed as the live Ruby method. An unregistered one
# keeps its interpreted body, which reads the ordinary ivar table while the
# compiled methods write the struct, and sees nil (in the desktop build: `nil >=
# x` in Scene::Map#step_parallel, swallowed by a rescue, killing every Parallel
# Process).
#
# Installation now comes from two sources, and either counts: bc2cpp.rb's own
# generated bc2cpp_register_owner_methods (OWNER_METHOD_REGISTRATION, emitted
# for every entry of a wired owner -- see that method's own comment for why
# this makes the invariant hold by construction) and any surviving hand
# mrb_define_method/mrb_define_private_method/mrb_define_class_method call in
# the gem's own register.cxx (harmlessly idempotent with a generated one for
# the same name+function).
#
# Runs the real generator once per compiled gem that owns a wired class and
# compares its "== compiled entry points ==" listing with what either source
# actually registers. Needs a host mrbc (MRBC), like the other bc2cpp checks;
# takes about as long as bc2cpp_coverage_report.rb per gem.

require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/static_dispatch_unregistered'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
srcs = closed_world_mrblib_srcs(root)
native = Dir["#{root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{root}/3rd/mruby") + external_gem_native_srcs(root)
foreign = foreign_mrblib_srcs(root)

# The identifier a `mrb_define_(private_|class_)?method(M, scope, "name", FN,
# aspec)` call actually installs -- the same shape a hand call in register.cxx
# and a generated call in bc2cpp_register_owner_methods both use.
# `bc2cpp_define_private_class_method` (emit_owner_registrations' own
# public-API stand-in for the mrb_define_private_class_method mruby doesn't
# ship) has the identical (M, scope, "name", FN, aspec) shape and needs to be
# recognized the same way, or a real private singleton registration would be
# reported as missing.
#
# The function-name group accepts `$`, not just `\w`: a generated symbol for an
# operator or predicate name carries the mangling's `$<hex>` escapes
# (`LCF__File_$5b$5d` for `LCF::File#[]`), and `\w+` stops at the first `$`, so
# every such registration read back as the bare `LCF__File_` and looked missing.
REGISTRATION_CALL = /(?:mrb_define_(?:private_|class_)?method|bc2cpp_define_private_class_method)\(\s*M\s*,\s*[^,]+,\s*(?:"[^"]*"|\S+)\s*,\s*([A-Za-z_][A-Za-z0-9_$]*)\s*,/m

failures = []
BC2CPP_COMPILED_GEMS.each do |name, gem|
  wired = gem[:owners] & BC2CPP_WIRED_EMBEDDINGS
  next if wired.empty?

  others = BC2CPP_COMPILED_GEMS.reject { |n, _| n == name }
  Dir.mktmpdir do |dir|
    env = {
      'MRBC' => mrbc, 'OUT_SYMBOL' => gem[:out_symbol], 'OUT_DIR' => dir,
      'ONLY_OWNERS' => gem[:owners].join(','),
      'OTHER_OWNERS' => others.values.flat_map { |x| x[:owners] }.join(','),
      'NATIVE_SRCS' => Shellwords.join(native), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign),
      'SKIP_UNSUPPORTED' => '1'
    }
    generated_path = File.join(dir, "#{gem[:out_symbol]}_gen.cpp")
    cmd = "#{RbConfig.ruby.shellescape} #{File.join(root, 'tools/bc2cpp/bc2cpp.rb').shellescape} " \
          "#{srcs.map(&:shellescape).join(' ')} > #{generated_path.shellescape}"
    _out, err, status = Open3.capture3(env, cmd)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-2000..]}" unless status.success?

    listing = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
    entries = listing.scan(%r{^\s+(\S+) / \S+\s+\((\S+)#(\S+), arity}).map { |entry, owner, method| [entry, owner, method] }
    register = File.read("#{root}/#{name}/src/register.cxx")
    generated = File.read(generated_path)
    identifiers = (register.scan(REGISTRATION_CALL) + generated.scan(REGISTRATION_CALL)).flatten.to_set
    # EMBEDDED_ACCESSOR_DEVIRT: an attr_reader/writer devirtualized for an
    # owner whose ivar is embedded must go through the synthesized struct
    # accessor -- the ivar table holds nil there (Game::Actor#id read via
    # mrb_iv_get broke RPG2003 battles). Every devirtualized accessor site
    # carries an `IVAR_ACCESSOR... :name -> Owner#@ivar` note; the code right
    # after it must not touch the ivar table for an embedded field.
    embedded = generated.scan(/^struct (\w+)_ivars \{\n(.*?)^\};/m).to_h do |sname, body|
      [sname, body.scan(/^\s+\w+ (\w+);/).flatten.to_set]
    end
    generated.scan(%r{// (?:LEXICAL_SELF_)?IVAR_ACCESSOR\S* :\S+ -> (\S+)#@(\w+) .*\n((?:.*\n){1,3})}) do |owner, ivar, code|
      next unless embedded[owner.gsub(/[^a-zA-Z0-9_]/, '_')]&.include?(ivar)

      site = code[/\A(?:  if \(.*\) \{\n)?.*\n/]
      next unless site.match?(/mrb_iv_[gs]et\(/)

      puts "  FAIL #{owner}#@#{ivar}: accessor devirtualized to the ivar table, but the ivar is embedded"
      failures << "#{owner}#@#{ivar} (accessor)"
    end

    wired.each do |owner|
      # A STATIC_DISPATCH_UNREGISTERED entry (docs/adr/0203) is deliberately
      # not installed: proven no runtime lookup can reach its name, so no
      # interpreted fallback -- the hazard this check exists for -- can ever
      # run for it. scripts/bc2cpp/static_dispatch_check.rb re-proves that.
      owned = entries.select { |_, o, m| o == owner && !STATIC_DISPATCH_UNREGISTERED.include?("#{o}##{m}") }
      missing = owned.reject { |entry, _, _| identifiers.include?(entry) }.map { |_, _, m| m }
      ok = missing.empty?
      puts "  #{ok ? 'ok  ' : 'FAIL'} #{owner}: #{owned.size - missing.size}/#{owned.size} compiled entry points installed by #{name}" \
           "#{ok ? '' : " (not installed: #{missing.first(8).join(', ')}#{missing.size > 8 ? ', ...' : ''})"}"
      failures << owner unless ok
    end
  end
end

if failures.empty?
  puts 'bc2cpp wired embedding check: PASS'
else
  warn "bc2cpp wired embedding check: #{failures.size} class(es) embedded without complete registration: " \
       "#{failures.join(', ')} -- register the missing entry points (generated or by hand) or drop the class " \
       'from BC2CPP_WIRED_EMBEDDINGS'
  exit 1
end
