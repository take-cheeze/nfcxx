#!/usr/bin/env ruby
# frozen_string_literal: true

# A class guard must honor a prepended override, including a VM-only body.
require_relative 'fixture_runtime'
ENV['BC2CPP_SIG_DIRS'] = ''
runtime = Bc2cppFixtureRuntime
source = <<~RUBY
  module PolyOverride
    def poly_shared(*args, **opts); super(*args, **opts) + 100; end
  end
  module PolyUnrelated
    def unrelated; 99; end
  end
  class PolyFirst
    def poly_shared; 1; end
  end
  class PolySecond
    def poly_shared; 2; end
  end
  class PolyThird
    def poly_shared; 3; end
  end
  PolyFirst.prepend(PolyOverride)
  PolySecond.prepend(PolyUnrelated)
  class PolyCaller
    def visit(object); object.poly_shared; end
  end
RUBY
owners = %w[PolyOverride PolyUnrelated PolyFirst PolySecond PolyThird PolyCaller]
Dir.mktmpdir('poly-prepend') do |dir|
  code, diagnostics = runtime.generate(source, dir, only_owners: owners)
  body = code[/mrb_value PolyCaller_visit_impl\([^)]*\) \{(.*?)^\}/m, 1]
  abort 'missing caller body' unless body
  abort 'class arm bypasses a prepended override' if body.include?('PolyFirst_poly_shared_impl(M,')
  abort 'the class without prepends lost its direct arm' unless body.include?('PolyThird_poly_shared_impl(M,')
  build = runtime.full_or_build
  abort 'full runtime required for prepend behavior check' unless build
  scenario = <<~CPP
    static int scenario(mrb_state* M) {
      mrb_value caller = mrb_obj_new(M, mrb_class_get(M, "PolyCaller"), 0, nullptr);
      mrb_value first = mrb_obj_new(M, mrb_class_get(M, "PolyFirst"), 0, nullptr);
      mrb_value second = mrb_obj_new(M, mrb_class_get(M, "PolySecond"), 0, nullptr);
      mrb_value third = mrb_obj_new(M, mrb_class_get(M, "PolyThird"), 0, nullptr);
      call(M, "override", caller, "visit", 1, &first);
      call(M, "unrelated", caller, "visit", 1, &second);
      call(M, "plain", caller, "visit", 1, &third);
      return 0;
    }
  CPP
  ok, output = runtime.run(dir, diagnostics, owners, scenario, build: build, full: true)
  abort output unless ok
  sections = runtime.sections(output).transform_values { |rows| rows.reject { |row| row.start_with?('  dispatches=') } }
  abort output unless sections['compiled'] == sections['interpreted'] &&
                      output.include?('override => 101') && output.include?('unrelated => 2') && output.include?('plain => 3')
end
puts 'poly prepend: lookup precedence, unrelated modules and runtime parity PASS'
