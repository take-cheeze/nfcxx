#!/usr/bin/env ruby
# encoding: UTF-8
# Compare opt-in interface tables with short chains, without the entry-wrapper cost.
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
abort 'needs a patched BC2CPP_MRUBY_CORE build and a C++ compiler' unless runtime.core && runtime.compiler?
source = (0...8).map { |i| "class Ib#{i}; def ib_tick; #{i}; end; end" }.join("\n") +
         "\nclass IbProbe; def tick(x); x.ib_tick; end; end\n"
owners = (0...8).map { |i| "Ib#{i}" } + ['IbProbe']
saved = ENV.values_at('BC2CPP_INTERFACE_TABLES', 'BC2CPP_CXXFLAGS')
begin
  ENV['BC2CPP_CXXFLAGS'] = "#{saved[1]} -O2"
  %w[0 1].each do |enabled|
    ENV['BC2CPP_INTERFACE_TABLES'] = enabled
    Dir.mktmpdir do |dir|
      code, err = runtime.generate(source, dir, only_owners: owners)
      abort 'benchmark did not select the requested dispatch mode' unless code.include?('INTERFACE_TABLE :ib_tick') == (enabled == '1')
      scenario = <<~CPP
        #include <ctime>
        static int scenario(mrb_state* M) {
          mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "IbProbe"), 0, nullptr);
          mrb_value values[8];
          for (int i = 0; i < 8; ++i) {
            char name[16]; std::snprintf(name, sizeof(name), "Ib%d", i);
            values[i] = mrb_obj_new(M, mrb_class_get(M, name), 0, nullptr);
          }
          const int calls = 2000000;
          for (int trial = 0; trial < 3; ++trial) {
            for (int mode = 0; mode < 3; ++mode) {
              mrb_int sum = 0;
              for (int i = 0; i < 10000; ++i) IbProbe_tick_impl(M, probe, values[mode == 0 ? 0 : mode == 1 ? 7 : i % 8]);
              std::clock_t start = std::clock();
              for (int i = 0; i < calls; ++i) {
                mrb_value out = IbProbe_tick_impl(M, probe, values[mode == 0 ? 0 : mode == 1 ? 7 : i % 8]);
                sum += mrb_integer(out);
              }
              double ns = 1e9 * double(std::clock() - start) / CLOCKS_PER_SEC / calls;
              std::printf("trial=%d receiver=%s ns_per_call=%.2f sum=%d\\n", trial,
                          mode == 0 ? "first" : mode == 1 ? "last" : "rotating", ns, int(sum));
            }
          }
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, owners, scenario, build: runtime.core, vms: [true])
      abort output unless built
      puts "mode=#{enabled == '1' ? 'table' : 'chain'} generated_bytes=#{code.bytesize} executable_bytes=#{File.size(File.join(dir, 'fixture'))}"
      puts output
    end
  end
ensure
  ENV['BC2CPP_INTERFACE_TABLES'], ENV['BC2CPP_CXXFLAGS'] = saved
end
