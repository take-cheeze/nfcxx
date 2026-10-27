# frozen_string_literal: true

require_relative 'codegen_block_core_direct'
require_relative 'source_text'

# COLLECT_DIRECT: a BLOCK_CORE_DIRECT arm for `map`/`collect` on an exact Array calls bc2cpp_ary_collect instead of
# the compiled Enumerable#collect. That body runs `self.each {|*val| ary.push(block.call(*val))}`, which builds two
# Arrays per element (the rest parameter and the splat) and goes through a second block; the helper is the same loop
# with neither. docs/bc2cpp-collect-direct.md has the equivalence.
#
# The arm already proves that `map` on Array is core Enumerable#collect; the helper also needs `each` to be core
# Array#each, and both bodies to be the text the helper follows (COLLECT_DIRECT_BODIES, read from the definitions'
# own source files on every compile). BC2CPP_COLLECT_DIRECT=0 keeps the compiled Enumerable#collect call.
#
# RANGE_COLLECT_DIRECT: the same for `map` and `each` on an exact Range whose bounds are Integers at run time
# (bc2cpp_range_collect / bc2cpp_range_each); any other Range takes the compiled body. docs/bc2cpp-collect-direct.md.
module CollectDirect
  COLLECT_DIRECT_BODIES = {
    %w[Enumerable collect] => <<~RUBY,
      def collect(&block)
        return to_enum(:collect) unless block
        ary = []
        self.each {|*val| ary.push(block.call(*val))}
        ary
      end
    RUBY
    %w[Array each] => <<~RUBY
      def each(&block)
        return to_enum(:each) unless block
        idx = 0
        while idx < length
          yield self[idx]
          idx += 1
        end
        self
      end
    RUBY
  }.freeze

  # RANGE_COLLECT_DIRECT: Range#each's opening, through its Integer-bounds branch. The helpers run only where that
  # branch is taken, so the rest of the body is not read.
  COLLECT_DIRECT_PREFIXES = {
    %w[Range each] => <<~RUBY
      def each(&block)
        return to_enum(:each) unless block
        val = self.begin
        last = self.end
        if val.kind_of?(Integer) && last.nil?
          i = val
          while true
            block.call(i)
            i += 1
          end
          return self
        end
        if val.kind_of?(String) && last.nil?
          if val.respond_to? :__upto_endless
            return val.__upto_endless(&block)
          else
            str_each = true
          end
        end
        if val.kind_of?(Integer) && last.kind_of?(Integer) # integers are special
          lim = last
          lim += 1 unless exclude_end?
          i = val
          while i < lim
            block.call(i)
            i += 1
          end
          return self
        end
    RUBY
  }.freeze

  # The methods Range#each's Integer path calls by name (Integer#+ and #< are instructions); RANGE_COLLECT_DIRECT
  # reads the Range and calls the block itself, so none may have another definition.
  RANGE_EACH_READERS = %w[begin end kind_of? nil? exclude_end? call].freeze
  RANGE_EACH_READER_OWNERS = %w[Range Enumerable Integer Numeric Comparable NilClass Proc Object Kernel BasicObject].freeze

  # Array#each re-reads the length and the slot on every pass, so a block that resizes the receiver sees what the
  # Ruby loop would. Only Array#push grows the result, so its capacity is not observable.
  # COLLECT_YIELD_HOIST: bc2cpp_yield_argv's compiled-block test is made once, since `blk` cannot change. A result is
  # stored before the arena is cut back to `ai`, so the arena holds `acc` (below `ai`), not one slot per element.
  # Nothing outside the helper sees `acc` before it returns, so it is never shared or frozen here.
  HELPER = <<~CPP
    static mrb_value bc2cpp_ary_collect(mrb_state* M, mrb_value self, mrb_value blk) {
      mrb_value acc = mrb_ary_new_capa(M, ARY_LEN(mrb_ary_ptr(self)));
      Bc2cppBlockEntry entry = nullptr;
      struct REnv* env = nullptr;
      if (mrb_type(blk) == MRB_TT_PROC) {
        struct RProc* p = mrb_proc_ptr(blk);
        if (MRB_PROC_CFUNC_P(p) && MRB_PROC_CFUNC(p) == bc2cpp_block_thunk && !MRB_PROC_STRICT_P(p)) {
          env = MRB_PROC_ENV(p);
          entry = bc2cpp_block_entry(env);
        }
      }
      int ai = mrb_gc_arena_save(M);
      for (mrb_int i = 0; i < ARY_LEN(mrb_ary_ptr(self)); ++i) {
        mrb_value v = ARY_PTR(mrb_ary_ptr(self))[i];
        mrb_value r = entry ? entry(M, env, false, 1, &v) : mrb_yield_argv(M, blk, 1, &v);
        struct RArray* a = mrb_ary_ptr(acc);
        if (!ARY_EMBED_P(a) && a->as.heap.len < a->as.heap.aux.capa) {
          a->as.heap.ptr[a->as.heap.len++] = r;
          mrb_field_write_barrier_value(M, (struct RBasic*)a, r);
        } else {
          mrb_ary_push(M, acc, r);
        }
        mrb_gc_arena_restore(M, ai);
      }
      return acc;
    }

  CPP

  # RANGE_COLLECT_DIRECT: Range#each's Integer branch, `block.call(i)` for i from begin up to end (or below it when
  # exclusive), with the call site's literal block, so `block.call` is the yield bc2cpp_ary_collect makes. The bounds
  # are read once, as the Ruby body reads them. An inclusive end at MRB_INT_MAX is left to the Ruby body: its
  # `lim += 1` leaves mrb_int there (a Float without bigint), and the loop it then runs is not this one.
  # Capacity is reserved for at most 0x10000 elements: a block may `break` out of a huge Range.
  RANGE_HELPER = <<~CPP
    static inline bool bc2cpp_range_int_p(mrb_state* M, mrb_value r) {
      mrb_value e = mrb_range_end(M, r);
      return mrb_integer_p(mrb_range_beg(M, r)) && mrb_integer_p(e) &&
             (mrb_range_excl_p(M, r) || mrb_integer(e) < MRB_INT_MAX);
    }
    static inline Bc2cppBlockEntry bc2cpp_range_block_entry(mrb_value blk, struct REnv** env) {
      if (mrb_type(blk) != MRB_TT_PROC) return nullptr;
      struct RProc* p = mrb_proc_ptr(blk);
      if (!MRB_PROC_CFUNC_P(p) || MRB_PROC_CFUNC(p) != bc2cpp_block_thunk || MRB_PROC_STRICT_P(p)) return nullptr;
      *env = MRB_PROC_ENV(p);
      return bc2cpp_block_entry(*env);
    }
    static mrb_value bc2cpp_range_collect(mrb_state* M, mrb_value self, mrb_value blk) {
      mrb_int a = mrb_integer(mrb_range_beg(M, self));
      mrb_int z = mrb_integer(mrb_range_end(M, self));
      mrb_bool excl = mrb_range_excl_p(M, self);
      mrb_int capa = 0;
      if (a <= z && (mrb_uint)z - (mrb_uint)a < 0x10000) capa = (mrb_int)((mrb_uint)z - (mrb_uint)a) + (excl ? 0 : 1);
      mrb_value acc = mrb_ary_new_capa(M, capa);
      struct REnv* env = nullptr;
      Bc2cppBlockEntry entry = bc2cpp_range_block_entry(blk, &env);
      int ai = mrb_gc_arena_save(M);
      for (mrb_int i = a; excl ? i < z : i <= z; ++i) {
        mrb_value v = FIXABLE(i) ? mrb_fixnum_value(i) : mrb_int_value(M, i);
        mrb_value r = entry ? entry(M, env, false, 1, &v) : mrb_yield_argv(M, blk, 1, &v);
        struct RArray* ary = mrb_ary_ptr(acc);
        if (!ARY_EMBED_P(ary) && ary->as.heap.len < ary->as.heap.aux.capa) {
          ary->as.heap.ptr[ary->as.heap.len++] = r;
          mrb_field_write_barrier_value(M, (struct RBasic*)ary, r);
        } else {
          mrb_ary_push(M, acc, r);
        }
        mrb_gc_arena_restore(M, ai);
      }
      return acc;
    }
    static mrb_value bc2cpp_range_each(mrb_state* M, mrb_value self, mrb_value blk) {
      mrb_int a = mrb_integer(mrb_range_beg(M, self));
      mrb_int z = mrb_integer(mrb_range_end(M, self));
      mrb_bool excl = mrb_range_excl_p(M, self);
      struct REnv* env = nullptr;
      Bc2cppBlockEntry entry = bc2cpp_range_block_entry(blk, &env);
      int ai = mrb_gc_arena_save(M);
      for (mrb_int i = a; excl ? i < z : i <= z; ++i) {
        mrb_value v = FIXABLE(i) ? mrb_fixnum_value(i) : mrb_int_value(M, i);
        if (entry) entry(M, env, false, 1, &v); else mrb_yield_argv(M, blk, 1, &v);
        mrb_gc_arena_restore(M, ai);
      }
      return self;
    }

  CPP

  def collect_direct_enabled?
    ENV['BC2CPP_COLLECT_DIRECT'] != '0'
  end

  # The arm's call, or nil to keep `arm[:impl]`. The helper always yields, so a nil block (`map(&nil)`, an absent
  # `&blk` passed on) takes the compiled Enumerable#collect, whose `to_enum(:collect)` arm answers it.
  def block_core_collect_call(arm, d, recv, args)
    return block_core_range_call(arm, d, recv, args) if arm[:class] == 'Range'
    return nil unless collect_direct_enabled? && arm[:class] == 'Array' && args.size == 1
    return nil unless core_body_is?(arm[:target], 'Enumerable', 'collect') && array_each_core?

    blk = args.first
    helper = "bc2cpp_ary_collect(M, #{recv}, #{blk})"
    return "r#{d} = #{helper};" if blk.match?(LITERAL_BLOCK_EXPR)

    "r#{d} = mrb_nil_p(#{blk}) ? #{arm[:impl]}(M, #{recv}, #{blk}) : #{helper};"
  end

  # The RProc a literal-block site builds (heap, stack or lazily heap-allocated), which is never nil. Any other
  # block expression gets the nil test.
  LITERAL_BLOCK_EXPR = /\A(?:mrb_obj_value\(bc2cpp_blk_proc_\d+\)|bc2cpp_blk_stack_\d+\.value\(\)|bc2cpp_blk_heap_\d+\(\))\z/

  def emit_collect_direct_helper(compiled)
    out = compiled.any? { |m| m[:code].include?('bc2cpp_ary_collect(') } ? HELPER.dup : +''
    out << RANGE_HELPER if compiled.any? { |m| m[:code].include?('bc2cpp_range_int_p(') }
    out
  end

  # BC2CPP_RANGE_COLLECT_DIRECT=0 keeps the compiled Enumerable#collect / Range#each call on a Range.
  def range_collect_direct_enabled?
    collect_direct_enabled? && ENV['BC2CPP_RANGE_COLLECT_DIRECT'] != '0'
  end

  private

  # RANGE_COLLECT_DIRECT: the arm's call for a literal block on an exact Range, or nil. Only the site's own literal
  # block is taken: it is never nil or a lambda, so `block.call(i)` is a plain yield. The helpers keep the block only
  # for the call, so they take the frame-local RProc when the site built one.
  def block_core_range_call(arm, d, recv, args)
    return nil unless range_collect_direct_enabled? && args.size == 1 && args.first.match?(LITERAL_BLOCK_EXPR)

    helper = if core_body_is?(arm[:target], 'Enumerable', 'collect') then 'bc2cpp_range_collect'
             elsif core_body_is?(arm[:target], 'Range', 'each') then 'bc2cpp_range_each'
             end
    return nil unless helper && range_each_core?

    blk = args.first
    fast_blk = blk == @call_block_expr && @call_block_stack_expr ? @call_block_stack_expr : blk
    "r#{d} = bc2cpp_range_int_p(M, #{recv}) ? #{helper}(M, #{recv}, #{fast_blk}) : #{arm[:impl]}(M, #{recv}, #{blk});"
  end

  # Range#each is the core body RANGE_COLLECT_DIRECT follows, and its Integer path's names are still mruby's own:
  # no program Ruby definition (on any owner), dynamic installer or outside definer, and no native registration on
  # the owners they resolve through other than mruby's src/*.c. Proc#call is the block call bc2cpp_ary_collect
  # already makes; only its Ruby definitions are looked for.
  def range_each_core?
    return @range_each_core unless @range_each_core.nil?

    installed = symbol_installed_names
    readers_plain = installed && RANGE_EACH_READERS.none? do |name|
      installed.include?(name) || (@registry[name] || []).any? { |definition| definition.owner != '<native>' } ||
        RANGE_EACH_READER_OWNERS.any? { |owner| range_reader_replaced?(owner, name) }
    end
    chain = BlockCoreDirectFallback::RECEIVERS.fetch('Range')[:chain]
    @range_each_core = !!readers_plain && core_body_is?(block_core_target('Range', chain, 'each', 0), 'Range', 'each')
  end

  def range_reader_replaced?(owner, name)
    return true if block_core_index.key?([owner, name]) || !block_core_world.core_ruby_arm_safe?(name, owner)
    return false if name == 'call'

    registrations, opaque = block_core_registrations
    return true if opaque.fetch(name, []).any? { |o| o.nil? || o == owner }

    registrations.fetch(name, []).any? do |registration|
      registration[:owner] && registration[:owner][:class_name] == owner && !mruby_core_native_source?(registration[:path])
    end
  end

  def mruby_core_native_source?(path)
    path && File.basename(File.dirname(path)) == 'src' && File.exist?(File.join(File.dirname(path), '../include/mruby.h'))
  end

  # Array#each reads `length` and `self[idx]` by name; the helper reads the RArray, so neither may be redefined.
  def array_each_core?
    return @array_each_core unless @array_each_core.nil?

    chain = BlockCoreDirectFallback::RECEIVERS.fetch('Array')[:chain]
    installed = symbol_installed_names
    readers_native = installed && %w[length []].none? { |reader| installed.include?(reader) || array_chain_defines?(reader, chain) }
    @array_each_core = !!readers_native &&
                       core_body_is?(block_core_target('Array', chain, 'each', 0), 'Array', 'each')
  end

  def array_chain_defines?(name, chain)
    (@registry[name] || []).any? { |definition| chain.include?(definition.owner) }
  end

  def core_body_is?(definition, owner, name)
    return false unless definition&.core && definition.owner == owner && definition.name == name

    (@collect_direct_bodies ||= {}).fetch([owner, name]) do
      @collect_direct_bodies[[owner, name]] = core_def_text_matches?(definition, owner)
    end
  end

  # Does the def read as COLLECT_DIRECT_BODIES says?
  def core_def_text_matches?(definition, owner)
    prefix = COLLECT_DIRECT_PREFIXES[[owner, definition.name]]
    core_def_text_is?(definition, prefix || COLLECT_DIRECT_BODIES[[owner, definition.name]], 'COLLECT_DIRECT',
                      prefix: !prefix.nil?)
  end

  # Does the def that starts at `definition`'s first line read as `expected` (or, with `prefix:`, begin with it),
  # blank lines and indentation aside?
  def core_def_text_is?(definition, expected, what, prefix: false)
    irep = @ireps[definition.irep]
    return false unless expected && irep&.file

    line = irep.instructions&.first&.lineno
    text = line && SourceText.read(irep.file, what)
    return false unless text

    lines = text.lines.drop(line - 1)
    indent = lines.first.to_s[/\A */]
    stop = lines.index { |l| l.chomp == "#{indent}end" }
    return false unless stop

    actual = normalize_def(lines[0..stop].join)
    prefix ? actual.start_with?("#{normalize_def(expected)}\n") : actual == normalize_def(expected)
  end

  def normalize_def(text)
    text.lines.map(&:strip).reject(&:empty?).join("\n")
  end
end

CodeGen.prepend(CollectDirect)
