# frozen_string_literal: true

require_relative '../../tools/bc2cpp/native_singletons'
require 'tmpdir'

module NativeSingletonCacheCases
  def self.run(check)
    saved_directory = ScanCache.directory_override
    original = NativeSingletons.method(:scan_file_table)
    scans = 0
    NativeSingletons.define_singleton_method(:scan_file_table) do |path|
      scans += 1
      original.call(path)
    end
    Dir.mktmpdir('native_singleton_cache') do |dir|
      ScanCache.directory_override = File.join(dir, 'cache')
      path = File.join(dir, 'binding.cxx')
      sibling = File.join(dir, 'init.cxx')
      File.write(path, <<~C)
        void bind(mrb_state *mrb, RClass *klass) {
          mrb_define_class_method(mrb, klass, "answer", impl, MRB_ARGS_NONE());
        }
      C
      source = <<~C
        void init(mrb_state *mrb) {
          RClass *c = mrb_define_module(mrb, "Alpha");
          bind(mrb, c);
        }
      C
      File.write(sibling, source)
      stamp = Time.at(Time.now.to_i, 100_000)
      File.utime(stamp, stamp, sibling)
      first = NativeSingletons.registered_owners('answer', [path])
      check.call('singleton owner follows a parameter passed from a sibling file', first == ['Alpha.singleton'])
      scans = 0
      check.call('repeat queries reuse the in-process table',
                 NativeSingletons.registered_owners('answer', [path]) == first && scans.zero?)
      NativeSingletons.instance_variable_set(:@files, {})
      check.call('a fresh in-process memo loads the disk table without scanning',
                 NativeSingletons.registered_owners('answer', [path]) == first && scans.zero?)

      stamp = File.mtime(sibling)
      File.write(sibling, source.sub('Alpha', 'Bravo'))
      File.utime(stamp + 0.001, stamp + 0.001, sibling)
      check.call('a same-size sibling rewrite within a second invalidates the owner',
                 NativeSingletons.registered_owners('answer', [path]) == ['Bravo.singleton'] && scans == 1)
      File.write(path, File.read(path).sub('"answer"', '"result"'))
      check.call('a rewritten binding invalidates its registrations',
                 NativeSingletons.registered_owners('answer', [path]) == [] &&
                 NativeSingletons.registered_owners('result', [path]) == ['Bravo.singleton'])
      File.write(path, File.read(path) + "\nconst char *extra = \"result\";")
      check.call('an unaccounted spelling still refuses direct singleton dispatch',
                 NativeSingletons.registered_owners('result', [path]).nil?)
    end
  ensure
    ScanCache.directory_override = saved_directory
    NativeSingletons.define_singleton_method(:scan_file_table, original)
    NativeSingletons.instance_variable_set(:@files, {})
  end
end
