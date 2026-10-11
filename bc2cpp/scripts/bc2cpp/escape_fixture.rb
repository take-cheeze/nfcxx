# frozen_string_literal: true

# Ruby fixtures shared by scripts/bc2cpp/escape_analysis_check.rb and its mutation check (ADR 0316).
module EscapeFixture
  # The unit fixture: one method per escape route or confined shape, each holding exactly one creation
  # site the check picks by its op (`c_*` confined, `e_*` escapes). Compiled alone: the callees below are
  # the whole world, so a name with no definition here is an unknown callee.
  UNIT = <<~'RUBY'
    class EaSink
      def run(f); f.call(1); end
      def each_one; yield 1; yield 2; end
      def keep(f); @f = f; nil; end
      def stash(&b); @b = b; nil; end
      def give(&b); b; end
      def one(&b); b.call(1); end
      def two(&b); one(&b); end
      def rec(n, &b); b.call(n); rec(n - 1, &b) if n > 0; end
      def via_each(a); a.each { |x| yield x }; end
      def forward(&b); stash(&b); end
      def quiet(x); x.size; end
      def arg_ret(x); x; end
      def chain(f); arg_ret(f); end
      def block_to_proc(&b); lambda(&b); end
      def self_ret; self; end
      def self_keep; @me = self; nil; end
      def self_call; quiet([self]); end
      def with_block_arg; yield; end
    end

    class EaU
      def initialize; @sink = EaSink.new; end

      # -- confined shapes
      def c_lambda_call; f = ->(n) { n + 1 }; f.call(1) + f.call(2); end
      def c_lambda_alias; f = ->(n) { n + 1 }; g = f; g.call(1); end
      def c_lambda_branch(c); f = ->(n) { n }; f.call(1) if c && f; end
      def c_lambda_loop; f = ->(n) { n }; i = 0; while i < 3; f.call(i); i += 1; end; i; end
      def c_lambda_arg; f = ->(n) { n }; @sink.run(f); end
      def c_lambda_block_arg; f = ->(n) { n }; @sink.one(&f); end
      def c_lambda_rescue; f = ->(n) { n }; begin; f.call(1); rescue ArgumentError; f.call(2); end; end
      def c_lambda_self_ref; fact = ->(n) { n <= 1 ? 1 : n * fact.call(n - 1) }; fact.call(4); end
      def c_lambda_read_by_block; f = ->(n) { n }; @sink.each_one { |x| f.call(x) }; end
      def c_block_yield; t = 0; @sink.each_one { |x| t += x }; t; end
      def c_block_two_frames; t = 0; @sink.two { |x| t += x }; t; end
      def c_block_recursive; t = 0; @sink.rec(3) { |x| t += x }; t; end
      def c_block_nested; t = 0; @sink.each_one { |x| @sink.each_one { |y| t += x * y } }; t; end
      def c_block_then_block; t = 0; @sink.each_one { |x| t += x }; @sink.each_one { |y| t -= y }; t; end
      def c_array_local; a = [1, 2]; a << 3; a.size; end
      def c_array_moves; a = [1, 2]; b = a; b.push(4); a.first; end
      def c_array_loop; a = []; i = 0; while i < 3; a << i; i += 1; end; a.size; end
      def c_string_local; s = 'ab'; s << 'c'; s.size; end
      def c_hash_local; h = { a: 1 }; h[:b] = 2; h.size; end

      # -- escapes
      def e_return; ->(n) { n }; end
      def e_return_via_move; f = ->(n) { n }; g = f; g; end
      def e_ivar; @l = ->(n) { n }; nil; end
      def e_gvar; $ea_l = ->(n) { n }; nil; end
      def e_cvar; @@ea_l = ->(n) { n }; nil; end
      def e_array; [->(n) { n }]; end
      def e_array_push; a = []; a << ->(n) { n }; a; end
      def e_hash; { f: ->(n) { n } }; end
      def e_index_set; a = []; a[0] = ->(n) { n }; nil; end
      def e_range; f = ->(n) { n }; (f..f); end
      def e_arg_stored; f = ->(n) { n }; @sink.keep(f); end
      def e_arg_returned; f = ->(n) { n }; @sink.chain(f); end
      def e_arg_unknown_callee; f = ->(n) { n }; @sink.not_defined_anywhere(f); end
      def e_receiver_unknown; f = ->(n) { n }; f.not_defined_anywhere; end
      def e_by_name_send; f = ->(n) { n }; f.send(:call, 1); end
      def e_public_send_arg; f = ->(n) { n }; @sink.public_send(:run, f); end
      def e_method_object; f = ->(n) { n }; f.method(:call); end
      def e_ivar_set; f = ->(n) { n }; instance_variable_set(:@x, f); end
      def e_to_proc; f = ->(n) { n }; f.to_proc; end
      def e_dup; f = ->(n) { n }; f.dup; end
      def e_raise; f = ->(n) { n }; raise f; end
      def e_call_with_self; f = ->(n) { n }; f.call(f); end
      def e_closure_escapes; f = ->(n) { n }; @sink.stash { f.call(1) }; end
      def e_closure_returned; f = ->(n) { n }; proc { f }; end
      def e_block_stashed; t = 0; @sink.stash { |x| t += x }; t; end
      def e_block_returned; t = 0; @sink.give { |x| t += x }; end
      def e_block_forwarded_to_stash; t = 0; @sink.forward { |x| t += x }; end
      def e_block_through_each; t = 0; @sink.via_each([1]) { |x| t += x }; t; end
      def e_block_unknown_callee; t = 0; @sink.not_defined_anywhere { |x| t += x }; t; end
      def e_block_by_name; t = 0; send(:puts) { |x| t += x }; t; end
      def e_block_proc_new; t = 0; Proc.new { |x| t += x }; end
      def e_block_proc; t = 0; proc { |x| t += x }; end
      def e_block_lambda; t = 0; lambda { |x| t += x }; end
      def e_block_define_method; t = 0; self.class.send(:define_method, :ea_dm) { t }; end
      def e_block_fiber; t = 0; Fiber.new { t += 1 }; end
      def e_block_lambda_of_param; @sink.block_to_proc { 1 }; end
      def e_array_element; f = ->(n) { n }; a = [f]; a; end
      def e_super; f = ->(n) { n }; super(f); end
      def e_setupvar; x = nil; ->(n) { x = n }; end
      def e_string_cat; t = 0; "#{->(n) { n }}"; end
      def e_class_body; f = ->(n) { n }; Class.new { define_method(:z) { f } }; end

      # -- the value is self
      def self_conf_quiet; @sink.quiet(self); end
    end
  RUBY

  # The program the generated-code and behaviour halves compile: callees whose names are outside
  # BLOCK_FALLBACK_UPVAR_SAFE_METHODS (so only the analysis can admit a block that captures a local to
  # them), the methods that pass them blocks (`p_*`, proven; `n_*`, not), and an EaOther that keeps its block.
  PROGRAM = <<~'RUBY'
    class EaSink
      def initialize; @cb = nil; end
      def keep(&b); @cb = b; nil; end
      def fire(x); @cb ? @cb.call(x) : :none; end
      def give(&b); b; end
    end

    class EaOther
      def spin2(n, &b); @k = b; n; end
      def kept; @k; end
    end

    class EaFx
      def initialize; @sink = EaSink.new; @log = []; end
      def log; @log; end

      def spin(n); i = 0; while i < n; yield i; i += 1; end; n; end
      def spin2(n); i = 0; while i < n; yield i; i += 1; end; n; end
      def pair_up; yield [1, 2]; yield 3, 4; yield 5; end
      def via_one(&b); spin(3, &b); end
      def via_two(&b); via_one(&b); end
      def walk(d, &b); return d if d == 0; b.call(d); walk(d - 1, &b); end
      def twice_fwd; spin(2) { |i| yield i + 100 }; end

      def p_sum(n); t = 0; spin(n) { |i| t += i }; t; end
      def p_nested(n); t = 0; spin(n) { |i| spin(n) { |j| t += i * j } }; t; end
      def p_two(n); t = 0; via_two { |x| t += x + n }; t; end
      def p_walk(n); out = []; walk(n) { |d| out << d }; out; end
      def p_break(n); spin(10) { |i| break i * n if i == 3 }; end
      def p_return(n); spin(5) { |i| return i * n if i == 2 }; :none; end
      def p_next(n); t = 0; spin(n) { |i| next if i % 2 == 1; t += i }; t; end
      def p_mutate(n); x = 1; spin(n) { |i| x += i; x *= 2 }; x; end
      def p_fwd(n); t = []; twice_fwd { |v| t << v + n }; t; end
      def p_gc(n); t = 0; spin(n) { |i| s = 'x' * 50; GC.start if i == 1; t += s.size }; t; end
      def p_destructure; t = []; pair_up { |a, b| t << [a, b] }; t; end
      def p_raise(n)
        t = 0
        begin
          spin(n) { |i| t += i; raise ArgumentError, 'boom' if i == 1 }
        rescue ArgumentError
          t += 100
        end
        t
      end
      def p_lambda(base); f = ->(x) { x + base }; f.call(1) + f.call(2); end
      def p_lambda_strict(base); f = ->(x) { x + base }; begin; f.call(1, 2); rescue ArgumentError; :strict; end; end
      def p_lambda_return(base); f = ->(x) { return x * base; 0 }; f.call(3) + 1; end

      def n_stash(n); t = [0]; @sink.keep { |x| t[0] += x + n }; nil; end
      def n_fire(x); @sink.fire(x); end
      def n_give(n); t = [0]; b = @sink.give { |x| t[0] += x + n }; [b, t]; end
      def n_send(n); t = 0; __send__(:spin, 3) { |i| t += i + n }; t; end
      def n_unknown(o, n); t = 0; o.spin2(2) { |i| @log << i + n; t += i }; t; end
      def n_proc(n); t = [0]; pr = Proc.new { |x| t[0] += x }; pr.call(n); pr.call(n); t[0]; end
      def n_lambda_m(n); t = [0]; l = lambda { |x| t[0] += x }; l.call(n); t[0]; end
      def n_fiber_yield(n); spin(2) { |i| Fiber.yield i + n }; :done; end
      def fiber_demo(n); f = Fiber.new { n_fiber_yield(n) }; [f.resume, f.resume, f.resume]; end
    end
  RUBY

  DRIVER = <<~'RUBY'
    fx = EaFx.new
    other = EaOther.new
    run = lambda do |label|
      cases = {
        p_sum: [0, 1, 5], p_nested: [2, 3], p_two: [1, 4], p_walk: [0, 3], p_break: [1, 4], p_return: [1, 7],
        p_next: [0, 6], p_mutate: [0, 3], p_fwd: [0, 2], p_gc: [0, 3, 40], p_destructure: [nil],
        p_raise: [1, 3], p_lambda: [0, 10], p_lambda_strict: [1], p_lambda_return: [3],
        n_send: [2], n_proc: [3], n_lambda_m: [4]
      }
      cases.each do |name, inputs|
        inputs.each_with_index do |input, i|
          out = begin
            input.nil? ? fx.__send__(name) : fx.__send__(name, input)
          rescue ArgumentError, RuntimeError => e
            [e.class, e.message]
          end
          puts "#{label} #{name}/#{i}: #{out.inspect}"
        end
      end
      fx.n_stash(5)
      puts "#{label} n_stash: #{fx.n_fire(1)} #{fx.n_fire(2)} #{fx.n_fire(3)}"
      held = fx.n_give(7)
      held[0].call(1)
      held[0].call(2)
      puts "#{label} n_give: #{held[1].inspect}"
      puts "#{label} n_unknown fx: #{fx.n_unknown(fx, 1)} #{fx.log.inspect}"
      puts "#{label} n_unknown other: #{fx.n_unknown(other, 1)}"
      other.kept.call(5)
      puts "#{label} n_unknown kept: #{fx.log.inspect}"
      # Array#combination: core Ruby whose block captures a local, compiled only with the analysis.
      if [].respond_to?(:combination)
        [[[1, 2, 3, 4], 2], [[1, 2, 3], 3], [[1, 2], 5], [[1, 2], 0]].each_with_index do |(ary, size), k|
          acc = []
          ret = ary.combination(size) { |c| acc << c.dup }
          puts "#{label} combination/#{k}: #{ret.equal?(ary)} #{acc.inspect}"
        end
        got = [1, 2, 3, 4].combination(2) { |c| break c if c[0] == 2 }
        puts "#{label} combination break: #{got.inspect}"
        wrapped = begin
          [1, 2, 3].combination(2) { |c| raise ArgumentError, 'stop' if c == [1, 3] }
        rescue ArgumentError => e
          e.message
        end
        puts "#{label} combination raise: #{wrapped.inspect}"
        count = 0
        (1..8).to_a.combination(4) { |c| count += c.size; GC.start if count % 97 == 0 }
        puts "#{label} combination big: #{count}"
        puts "#{label} combination enum: #{[1, 2, 3].combination(2).to_a.inspect}"
      end
    end
    run.call('plain')
    puts "fiber: #{fx.fiber_demo(10).inspect}" if Object.const_defined?(:Fiber)
    if GC.respond_to?(:interval_ratio=)
      GC.interval_ratio = 100
      GC.step_ratio = 200
      GC.generational_mode = false
    end
    run.call('stress')
    puts 'end'
  RUBY
end
