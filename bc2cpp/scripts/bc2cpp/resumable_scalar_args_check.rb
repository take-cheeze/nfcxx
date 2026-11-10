#!/usr/bin/env ruby
# frozen_string_literal: true

# Fixed 0/1-argument block suspensions keep their arguments in the frame's GC
# register array. Frame#value materializes the legacy packed Array on demand.
# Run with BC2CPP_MRUBY_FULL pointing to an MRB_GC_STRESS build to stress roots.
require_relative 'check_support'
require_relative 'fixture_runtime'
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('resumable_scalar_args_check')
suite.require_mrbc!

source = <<~'RUBY'
  class ScalarArgs
    def start
      @fiber = Fiber.new { marks { |*args| GC.start; Fiber.yield args; :resumed } }
    end

    def marks(&blk)
      seen = []
      seen << yield
      seen << yield(nil)
      seen << yield(["a", "b"])
      seen << yield("c", "d")
      args = ["e", "f"]
      seen << blk.call(*args)
      seen
    end

    def pairs(&blk)
      yield [1, 2]
      :done
    end

    def start_pairs
      @fiber = Fiber.new { pairs { |a, b| GC.start; Fiber.yield [a, b] } }
    end

    def go
      @fiber.resume
    end
  end
RUBY

driver = <<~'RUBY'
  a = ScalarArgs.new
  b = ScalarArgs.new
  a.start
  b.start_pairs
  out = []
  out << a.go
  out << b.go
  5.times { GC.start; out << a.go }
  out << b.go
  p out
RUBY

Dir.mktmpdir('resumable_scalar_args') do |dir|
  code, diagnostics = Bc2cppFixtureRuntime.generate(source, dir, core: true, only_owners: %w[ScalarArgs])
  suite.check('zero and one argument block calls use scalar suspensions',
              code.include?('F->block_call = 3; // scalar block arguments') &&
              code.include?('F->block_call = 4; // scalar block arguments'))
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        mrb_load_string(M, R"RUBY(#{driver})RUBY");
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); return 1; }
        bc2cpp_resumable_init(M);
        mrb_value frame = mrb_nil_value();
        Bc2cppResumeFrame* f = bc2cpp_resume_frame(M, &frame, 1, 0);
        f->regs[0] = mrb_str_new_lit(M, "retained");
        f->block_call = 4;
        mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(f->regs_ary));
        mrb_full_gc(M);
        if (bc2cpp_resume_frame_argc(f) != 1 || !mrb_string_p(bc2cpp_resume_frame_argv(f)[0])) return 2;
        mrb_value first = bc2cpp_resume_frame_value(M, frame);
        if (!mrb_array_p(first) || RARRAY_LEN(first) != 1 || RSTRING_LEN(RARRAY_PTR(first)[0]) != 8) return 3;
        if (!mrb_obj_eq(M, first, bc2cpp_resume_frame_value(M, frame))) return 4;
        if (bc2cpp_resume_frame_argc(f) != 1 || !mrb_string_p(bc2cpp_resume_frame_argv(f)[0])) return 5;
        f->regs[0] = mrb_nil_value();
        f->block_call = 3;
        if (bc2cpp_resume_frame_argc(f) != 0) return 6;
        first = bc2cpp_resume_frame_value(M, frame);
        if (!mrb_array_p(first) || RARRAY_LEN(first) != 0) return 7;
        if (!mrb_obj_eq(M, first, bc2cpp_resume_frame_value(M, frame))) return 8;
        f->block = mrb_load_string(M, "proc { |*args| GC.start; args }");
        f->regs[2] = f->block;
        mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(f->regs_ary));
        f->regs[0] = mrb_str_new_lit(M, "from C");
        f->block_call = 4;
        mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(f->regs_ary));
        mrb_value result = bc2cpp_resumable_resume_from_c(M, frame);
        if (!mrb_array_p(result) || RARRAY_LEN(result) != 1 || RSTRING_LEN(RARRAY_PTR(result)[0]) != 6) return 9;
        f->regs[0] = mrb_nil_value();
        f->block_call = 3;
        result = bc2cpp_resumable_resume_from_c(M, frame);
        if (!mrb_array_p(result) || RARRAY_LEN(result) != 0) return 10;
        return 0;
      }
    CPP
    ok, output = Bc2cppFixtureRuntime.run(dir, diagnostics, %w[ScalarArgs], body, build: build, full: true)
    suite.check('scalar argument storage and lazy Frame#value survive full GC and preserve identity', ok)
    sections = Bc2cppFixtureRuntime.sections(output)
    sections.transform_values! { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
    suite.check('zero/nil, array destructuring, multi-argument, splat, and interleaved fibers match bytecode',
                sections['interpreted'] == sections['compiled'] &&
                sections['compiled'] == ['[[], [1, 2], [nil], [["a", "b"]], ["c", "d"], ["e", "f"], [:resumed, :resumed, :resumed, :resumed, :resumed], :done]'])
    puts output unless ok && sections['interpreted'] == sections['compiled']
  else
    puts 'SKIP behaviour: needs a full-core mruby build'
  end
end

suite.finish!
