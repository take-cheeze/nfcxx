# frozen_string_literal: true

# The fixture, driver and C++ scenario of the `- & | <<` helper matrix of scripts/bc2cpp/numeric_slow_check.rb
# Unlike the arithmetic matrices, the receivers and operands are built fresh for every call (a lambda
# each), because `<<` mutates its receiver and `Array#-` / `&` / `|` call a user `hash`, `eql?` and `==` that log.
# Each case compares the closed helper called directly with the real operator, over: result or error (class and
# message), the result's class, frozen-ness and identity with the receiver, the receiver and operand afterwards, the
# calls the elements' own methods logged, and what an IO wrote.

module Bc2cppCollectionOpsMatrix
  OWNERS = %w[NsColl NsCollBox NsCollPlain NsCollConv NsCollAry NsCollStr NsCollFile].freeze # the element classes stay bytecode (their `==` would pull rgss arms)

  # Nothing here defines `- & | <<` (NsCollBox answers none), so all four helpers close in a world with mruby-array-ext,
  # mruby-string-ext and mruby-io and no other `<<` definer (the closed gem list less mruby-enumerator's Yielder).
  FIXTURE = <<~RUBY
    class NsCollBox
      def inspect = "collbox"
    end
    class NsCollPlain
      def inspect = "plain"
    end
    class NsCollKey
      attr_reader :n
      def initialize(n)
        @n = n
      end
      def hash
        $log << [:hash, @n]
        @n.hash
      end
      def eql?(o)
        $log << [:eql, @n]
        o.is_a?(NsCollKey) && @n == o.n
      end
      def ==(o)
        $log << [:eq, @n]
        o.is_a?(NsCollKey) && @n == o.n
      end
      def to_s = "k\#{@n}"
      def inspect = "key\#{@n}"
    end
    class NsCollBadKey
      def hash = raise("bad hash")
      def eql?(o) = raise("bad eql")
      def ==(o) = raise("bad ==")
      def to_s = raise("bad to_s")
      def inspect = "badkey"
    end
    class NsCollConv
      def to_s = "conv"
      def to_str = "convstr"
      def to_ary = [9]
      def inspect = "conv"
    end
    class NsCollAry < Array
    end
    class NsCollStr < String
    end
    class NsCollFile < File
    end
    class NsColl
      def sub(a, b) = a - b
      def band(a, b) = a & b
      def bor(a, b) = a | b
      def lsh(a, b) = a << b

      def arena(a, b, op)
        w = NsProbe.arena
        case op
        when 0 then a - b
        when 1 then a & b
        when 2 then a | b
        else a << b
        end
        NsProbe.arena - w
      end

      def dispatched(a, b, op)
        w = NsProbe.dispatches
        case op
        when 0 then a - b
        when 1 then a & b
        when 2 then a | b
        else a << b
        end
        NsProbe.dispatches - w - 1 # the second probe call is itself one dispatch
      end

      # Arrays and Strings built and dropped under GC pressure.
      def churn(n)
        acc = [0]
        s = +""
        i = 0
        while i < n
          acc = (acc | [i, i + 1]) - [i - 3]
          acc = acc & acc
          acc << i
          s << "ab"
          s << 99
          s = s[-30, 30] if s.size > 60
          acc = acc.last(20) if acc.size > 40
          GC.start if i % 50 < 1
          i += 1
        end
        [acc, s]
      end
    end
  RUBY

  # `c` is the width's own constants: FM (top Fixnum), IM (top mrb_int); `$bigint` says whether heap Integers exist.
  def self.driver(width_consts)
    <<~RUBY
      #{width_consts}
      $log = []
      def ns_reset = $log.clear
      def ns_lbl(v)
        case v
        when Array, String, Symbol, Integer, Float, NilClass, TrueClass, FalseClass, Range, Hash
          s = v.inspect
          s = s[0, 120] + "...(\#{s.size})" if s.size > 120
          s += " cls=\#{v.class}" if v.is_a?(Array) || v.is_a?(String)
          s += " frozen" if v.frozen? && (v.is_a?(Array) || v.is_a?(String))
          s += " h=\#{v.hash}" if v.is_a?(Integer)
          s
        else
          v.is_a?(NsCollKey) || v.instance_of?(NsCollBox) || v.instance_of?(NsCollPlain) ? v.inspect : v.class.to_s
        end
      end
      def ns_io_data(a)
        return "" unless a.is_a?(IO) && $pipe_r
        r = $pipe_r
        $pipe_r = nil
        begin
          a.close unless a.closed?
          r.read.inspect
        rescue => e
          "io? \#{e.class}"
        ensure
          r.close
        end
      end
      # The log is the set of calls the elements saw, not their number or order: which keys collide in a hash table
      # depends on the VM's hash seed and on the addresses of elements without their own `hash`.
      def ns_state(res, raised, a, b, norm = false)
        log = $log.uniq.sort_by(&:inspect)
        head = raised ? "raised \#{res.class}: \#{res.message}" : "\#{ns_lbl(res)} same=\#{res.equal?(a)}"
        "\#{head} | a=\#{ns_lbl(a)} b=\#{ns_lbl(b)} log=\#{log.inspect} io=\#{ns_io_data(a)}"
      end
      def ns_pipe_w
        r, w = IO.pipe
        $pipe_r = r
        w
      end

      ary = {
        'empty' => -> { [] }, 'one' => -> { [1] }, 'ints' => -> { [1, 2, 3, 2, 1] },
        'mixed' => -> { [1, "a", :b, nil, 2.5, [1], {a: 1}] }, 'nested' => -> { [[1], [2], [1]] },
        'frozen' => -> { [1, 2].freeze }, 'frozen_empty' => -> { [].freeze }, 'subclass' => -> { NsCollAry.new([1, 2, 3]) },
        'shared' => -> { (0...40).to_a.dup }, 'slice' => -> { (0...40).to_a[5, 20] },
        'big' => -> { (0...100).to_a }, 'bigdup' => -> { (0...100).to_a * 2 },
        'keys' => -> { [NsCollKey.new(1), NsCollKey.new(2), NsCollKey.new(1)] },
        'keys_other' => -> { [NsCollKey.new(2), NsCollKey.new(3)] },
        'bigkeys' => -> { (0...40).map { |i| NsCollKey.new(i % 7) } },
        'badkey' => -> { [NsCollBadKey.new] }, 'badkey_big' => -> { [NsCollBadKey.new] * 40 },
        'floats' => -> { [1.0, 2, 0.0, -0.0, 3] }, 'nan' => -> { [Float::NAN, 1] },
        'strs' => -> { ["a", "b", "a", "\\u3042"] }, 'syms' => -> { [:a, :b, :a] }, 'nils' => -> { [nil, nil, false, true] },
        'huge' => -> { Array.new(70000, 0) },
        'conv' => -> { [NsCollConv.new] }
      }
      noary = {
        'nil' => -> { nil }, 'int' => -> { 1 }, 'str' => -> { "s" }, 'sym' => -> { :a }, 'hash' => -> { {a: 1} },
        'range' => -> { 1..2 }, 'obj' => -> { NsCollPlain.new }, 'box' => -> { NsCollBox.new }, 'class' => -> { Array },
        'conv' => -> { NsCollConv.new }, 'float' => -> { 1.5 }, 'true' => -> { true }
      }
      scal = {
        'nil' => -> { nil }, 'true' => -> { true }, 'false' => -> { false }, '0' => -> { 0 }, '1' => -> { 1 }, '-1' => -> { -1 },
        '2' => -> { 2 }, '7' => -> { 7 }, 'fm' => -> { FM }, 'im' => -> { IM }, '-im' => -> { -IM - 1 },
        'float' => -> { 1.5 }, 'nan' => -> { Float::NAN }, 'str' => -> { "s" }, 'sym' => -> { :a }, 'ary' => -> { [1] },
        'hash' => -> { {a: 1} }, 'range' => -> { 1..2 }, 'box' => -> { NsCollBox.new }, 'obj' => -> { NsCollPlain.new }
      }
      big = { 'big' => -> { 2 ** 100 }, '-big' => -> { -(2 ** 100) }, 'fm+1' => -> { FM + 1 }, 'im+1' => -> { IM + 1 } }
      scal.merge!(big) if $bigint
      str = {
        'empty' => -> { +"" }, 'ab' => -> { +"ab" }, 'utf8' => -> { +"\\u3042\\u3044" }, 'frozen' => -> { "x".freeze },
        'subclass' => -> { NsCollStr.new("xy") }, 'long' => -> { +("a" * 3000) }, 'bin' => -> { +"\\xff\\x00" }
      }
      sarg = {
        'str' => -> { "s" }, 'utf8' => -> { "\\u3044" }, 'empty' => -> { "" }, 'frozen' => -> { "z".freeze }, 'nul' => -> { "\\0" },
        'sub' => -> { NsCollStr.new("q") }, 'same' => -> { x = +"ab"; x },
        '65' => -> { 65 }, '0' => -> { 0 }, '255' => -> { 255 }, '256' => -> { 256 }, '-1' => -> { -1 },
        '0x3042' => -> { 0x3042 }, 'float' => -> { 66.7 }, 'nan' => -> { Float::NAN }, 'nil' => -> { nil },
        'sym' => -> { :sym }, 'ary' => -> { ["a"] }, 'conv' => -> { NsCollConv.new }, 'key' => -> { NsCollKey.new(3) },
        'bad' => -> { NsCollBadKey.new }, 'obj' => -> { NsCollPlain.new }
      }
      str['big'] = -> { 2 ** 100 } if $bigint
      ioargs = {
        'str' => -> { "io" }, 'utf8' => -> { "\\u3042" }, 'empty' => -> { "" }, 'int' => -> { 12 }, 'nil' => -> { nil },
        'ary' => -> { [1, "a"] }, 'sym' => -> { :s }, 'key' => -> { NsCollKey.new(5) }, 'bad' => -> { NsCollBadKey.new },
        'float' => -> { 1.5 }
      }
      io = {
        'pipe_w' => -> { ns_pipe_w },
        'pipe_r' => -> { r, w = IO.pipe; $pipe_w = w; r },
        'closed' => -> { w = ns_pipe_w; w.close; w },
        'null' => -> { File.open("/dev/null", "w") },
        'file_sub' => -> { NsCollFile.open("/dev/null", "w") }
      }
      shifts = ($bigint ? [2 ** 100, FM, FM + 1, -IM, -(2 ** 70)] : [FM, -IM]) +
               [0, 1, -1, 2, 5, 30, 31, 32, 33, 62, 63, 64, 65, 100, -2, -30, -31, -32, -62, -63, -64, -65, -100,
                IM, -IM - 1, 2.5, -2.5, nil, "s", 1.0e19, Float::NAN, [1], true]
      ints = [0, 1, -1, 2, -2, 3, 7, -7, FM, FM - 1, -FM, -FM - 1, IM, -IM, -IM - 1]
      ints += [FM + 1, -FM - 2, IM + 1, 2 ** 100, -(2 ** 100)] if $bigint
      non_int = [0.5, nil, "s", :sym, [1], true, false]
      $cases = Hash.new { |h, k| h[k] = [] }
      add = lambda do |op, recvs, args|
        recvs.each { |ra, rp| args.each { |aa, ap| $cases[op] << ["\#{ra} \#{aa}", rp, ap] } }
      end
      # `-`, `&`, `|`: Array receivers against every operand; `&` and `|` also take nil, true, false and Integers.
      %w[sub band bor].each { |op| add.call(op, ary, ary.merge(noary)) }
      %w[band bor].each { |op| add.call(op, scal, scal) }
      add.call('sub', scal.select { |k, _| %w[nil 1 float str ary].include?(k) }, ary.merge(noary))
      # `<<`: Array receivers take any operand, String receivers strings and codepoints, IO receivers anything with to_s.
      add.call('lsh', ary, ary.merge(noary).merge(sarg))
      add.call('lsh', str, sarg)
      add.call('lsh', io, ioargs)
      add.call('lsh', { 'nil' => scal['nil'], 'true' => scal['true'], 'float' => scal['float'], 'sym' => scal['sym'] }, sarg)
      shift_lambda = ->(v) { -> { v.is_a?(Array) || v.is_a?(String) ? v.dup : v } }
      ints.each do |a|
        shifts.each { |b| $cases['lsh'] << ["int \#{a.inspect} \#{b.inspect}", shift_lambda.call(a), shift_lambda.call(b)] }
      end
      non_int.each { |a| shifts.first(8).each { |b| $cases['lsh'] << ["non \#{a.inspect} \#{b.inspect}", shift_lambda.call(a), shift_lambda.call(b)] } }
      # An Integer receiver reads a non-Integer operand of `&` `|` as the method does (an address for a heap object),
      # which differs between two runs: those pairs are only in the direct matrix.
      o = NsColl.new
      $cases.each do |op, cases|
        cases.each do |label, mka, mkb|
          next if %w[band bor].include?(op) && mka.call.is_a?(Integer) && !(mkb.call.is_a?(Numeric) || [nil, true, false, :sym].include?(mkb.call))
          ns_reset
          a = mka.call
          b = mkb.call
          line = begin
            ns_state(o.send(op, a, b), false, a, b, true)
          rescue => e
            ns_state(e, true, a, b, true)
          end
          puts "\#{op} \#{label} => \#{line}"
        end
      end
      # Dispatch counts and arena depths: two-space lines, which the comparison skips.
      [[[1, 2], [2]], [[1], [1, 2]], [[], []]].each do |a, b|
        [['sub', 0], ['band', 1], ['bor', 2], ['lsh', 3]].each do |op, k|
          puts "  D \#{op} 1 \#{a.inspect} \#{b.inspect} \#{(o.dispatched(a.dup, b.dup, k) rescue -1)}"
          puts "  A \#{op} \#{a.inspect} \#{b.inspect} \#{(o.arena(a.dup, b.dup, k) rescue -1)}"
        end
      end
      [[+"ab", +"cd"], [+"ab", 99]].each do |a, b|
        puts "  D lsh 1 \#{a.inspect} \#{b.inspect} \#{(o.dispatched(a, b, 3) rescue -1)}"
        puts "  A lsh \#{a.inspect} \#{b.inspect} \#{(o.arena(a, b, 3) rescue -1)}"
      end
      [[3, 2], [7, 1], [6, 3], [0, 1], [1, 100]].each do |a, b|
        [['sub', 0], ['band', 1], ['bor', 2], ['lsh', 3]].each do |op, k|
          puts "  D \#{op} 1 \#{a} \#{b} \#{(o.dispatched(a, b, k) rescue -1)}"
        end
      end
      [[nil, 1], [true, nil], [false, 3]].each do |a, b|
        [['band', 1], ['bor', 2]].each { |op, k| puts "  D \#{op} 1 \#{a.inspect} \#{b.inspect} \#{(o.dispatched(a, b, k) rescue -1)}" }
      end
      $bigint && [[2 ** 70, 3], [3, 2 ** 70], [2 ** 70, 2 ** 70]].each do |a, b|
        [0, 1, 2, 3].each { |k| puts "  A big\#{k} \#{a} \#{b} \#{(o.arena(a, b, k) rescue -1)}" }
      end
      puts "churn => \#{o.churn(2000).inspect}"
      puts 'end'
    RUBY
  end

  # Each helper called directly against the operator it stands for, over every case of $cases[op], fresh operands
  # for each of the two calls. The state string covers result, errors, mutation and logs.
  SCENARIO = <<~CPP
    #include <string>
    struct CollSpec { const char* name; const char* op; mrb_value (*fn)(mrb_state*, mrb_value, mrb_value); };
    static const CollSpec coll_specs[] = {
      { "sub", "-", bc2cpp_slow_sub_f }, { "band", "&", bc2cpp_slow_and }, { "bor", "|", bc2cpp_slow_or },
      { "lsh", "<<", bc2cpp_slow_lshift },
    };
    struct CollCall { const CollSpec* s; mrb_value a, b; bool method; };
    static mrb_value coll_body(mrb_state* M, void* ud) {
      CollCall* k = (CollCall*)ud;
      return k->method ? (mrb_funcall)(M, k->a, k->s->op, 1, k->b) : k->s->fn(M, k->a, k->b);
    }
    static std::string coll_state(mrb_state* M, mrb_value res, bool raised, mrb_value a, mrb_value b) {
      mrb_value args[4] = { res, mrb_bool_value(raised), a, b };
      mrb_value s = (mrb_funcall_argv)(M, mrb_top_self(M), mrb_intern_cstr(M, "ns_state"), 4, args);
      return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
    }
    static int scenario(mrb_state* M) {
      RClass* probe = mrb_define_module(M, "NsProbe");
      mrb_define_class_method(M, probe, "arena", [](mrb_state* M, mrb_value) { return mrb_fixnum_value(mrb_gc_arena_save(M)); }, MRB_ARGS_NONE());
      mrb_define_class_method(M, probe, "dispatches", [](mrb_state*, mrb_value) { return mrb_fixnum_value(dispatches); }, MRB_ARGS_NONE());
      std::fflush(stdout);
      const char* src = R"BCD(__SOURCE__)BCD";
      mrb_load_string(M, src);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      mrb_value cases = mrb_gv_get(M, mrb_intern_lit(M, "$cases"));
      int total = 0, bad = 0, errors = 0;
      for (const CollSpec& s : coll_specs) {
        mrb_value list = (mrb_funcall)(M, cases, "fetch", 2, mrb_str_new_cstr(M, s.name), mrb_ary_new(M));
        int n = 0, wrong = 0;
        for (mrb_int i = 0; i < RARRAY_LEN(list); ++i) {
          int ai = mrb_gc_arena_save(M);
          mrb_value row = RARRAY_PTR(list)[i];
          mrb_value label = RARRAY_PTR(row)[0], mka = RARRAY_PTR(row)[1], mkb = RARRAY_PTR(row)[2];
          std::string state[2];
          for (int method = 0; method < 2; ++method) {
            (mrb_funcall)(M, mrb_top_self(M), "ns_reset", 0);
            CollCall call = { &s, (mrb_funcall)(M, mka, "call", 0), (mrb_funcall)(M, mkb, "call", 0), method == 1 };
            mrb_bool raised = FALSE;
            mrb_value res = mrb_protect_error(M, coll_body, &call, &raised);
            state[method] = coll_state(M, res, raised, call.a, call.b);
            if (method == 1 && raised) ++errors;
          }
          mrb_gc_arena_restore(M, ai);
          ++n;
          if (state[0] != state[1]) {
            ++wrong;
            if (wrong <= 5) {
              mrb_value l = mrb_inspect(M, label);
              std::printf("  H MISMATCH %s %.*s\\n    helper=%s\\n    method=%s\\n", s.name, (int)RSTRING_LEN(l), RSTRING_PTR(l),
                          state[0].c_str(), state[1].c_str());
            }
          }
        }
        std::printf("  H op %s %d cases, %d mismatches\\n", s.name, n, wrong);
        total += n;
        bad += wrong;
      }
      std::printf("  H summary %d cases, %d mismatches, %d errors\\n", total, bad, errors);
      return 0;
    }
  CPP
end
