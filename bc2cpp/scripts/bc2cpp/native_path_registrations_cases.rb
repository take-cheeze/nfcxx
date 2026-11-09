# frozen_string_literal: true

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/native_names'
require_relative '../../tools/bc2cpp/native_expression_devirt'

module NativePathRegistrationsCases
  NED = NativeExpressionDevirt
  SOURCE = <<~C
    static mrb_value nil_extra(mrb_state *mrb, mrb_value self) { return self; }
    static mrb_value thing_size(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(1); }
    static const mrb_mt_entry thing_rom[] = {
      MRB_MT_ENTRY(thing_size, MRB_SYM(size), MRB_ARGS_NONE()),
    };
    void mrb_thing_gem_init(mrb_state *mrb) {
      struct RClass *thing = mrb_define_class_id(mrb, MRB_SYM(Thing), mrb->object_class);
      MRB_SET_INSTANCE_TT(thing, MRB_TT_DATA);
      MRB_MT_INIT_ROM(mrb, thing, thing_rom);
      mrb_define_method_id(mrb, mrb->nil_class, MRB_SYM(extra), nil_extra, MRB_ARGS_NONE());
      mrb_define_method(mrb, unknown_var, "mystery", nil_extra, MRB_ARGS_NONE());
    }
  C

  def self.run(check)
    # Counts the scans, as scan_cache_check.rb does.
    scans = 0
    original = NED.method(:scan_class_registrations)
    NED.define_singleton_method(:scan_class_registrations) do |*args|
      scans += 1
      original.call(*args)
    end

    begin
      Dir.mktmpdir('native_path_registrations') do |dir|
        path = File.join(dir, 'thing.c')
        File.write(path, SOURCE)
        fresh = original.call([path])
        first = NED.path_registrations(path)
        check.call('the answer equals a fresh scan of the path', first == fresh && fresh[0].key?('size') && fresh[1].key?('extra'))
        check.call('the fixture registers size on Thing, extra and mystery opaquely',
                   first[0].fetch('size').map { |entry| entry[:owner][:class_name] } == ['Thing'] &&
                   first[1].fetch('extra') == ['Nil'] && first[1].fetch('mystery') == [nil])

        scans = 0
        second = NED.path_registrations(path)
        check.call('a second ask returns the same maps without scanning', second.equal?(first) && scans.zero?)
        check.call('the maps and their entry lists are frozen',
                   first.frozen? && first.all?(&:frozen?) && first.all? { |map| map.values.all?(&:frozen?) })
        check.call('fetch on a frozen map still answers a missing name', first[0].fetch('nope', []) == [])

        File.write(path, SOURCE.sub('MRB_SYM(size)', 'MRB_SYM(length)'))
        scans = 0
        rewritten = NED.path_registrations(path)
        check.call('a rewritten source is scanned again', scans == 1 && rewritten[0].key?('length') && !rewritten[0].key?('size'))

        missing = File.join(dir, 'missing.c')
        scans = 0
        gone = [NED.path_registrations(missing), NED.path_registrations(missing)]
        check.call('a path that is not a file answers empty maps, uncached',
                   gone.all? { |maps| maps.all?(&:empty?) } && scans == 2 && !NED::PATH_REGISTRATIONS.key?(missing))
      end
    ensure
      NED.define_singleton_method(:scan_class_registrations, original)
    end

    pools = File.read(File.expand_path('../../tools/bc2cpp/codegen_class_pools.rb', __dir__))
    refusal = pools[/def nil_unanswerable_refusal.*?\n  end\n/m].to_s
    check.call('nil_unanswerable_refusal reads the native registrations through path_registrations',
               refusal.include?('NativeExpressionDevirt.path_registrations(path)') &&
               !refusal.include?('scan_class_registrations'))
  end
end
