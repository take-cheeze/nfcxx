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

  # Array#each re-reads the length and the slot on every pass, so a block that resizes the receiver sees what the
  # Ruby loop would. Only Array#push grows the result, so its capacity is not observable.
  HELPER = <<~CPP
    static mrb_value bc2cpp_ary_collect(mrb_state* M, mrb_value self, mrb_value blk) {
      mrb_value acc = mrb_ary_new_capa(M, ARY_LEN(mrb_ary_ptr(self)));
      for (mrb_int i = 0; i < ARY_LEN(mrb_ary_ptr(self)); ++i) {
        mrb_value v = ARY_PTR(mrb_ary_ptr(self))[i];
        mrb_ary_push(M, acc, bc2cpp_yield_argv(M, blk, 1, &v));
      }
      return acc;
    }

  CPP

  def collect_direct_enabled?
    ENV['BC2CPP_COLLECT_DIRECT'] != '0'
  end

  # The arm's call, or nil to keep `arm[:impl]`.
  def block_core_collect_call(arm, d, recv, args)
    return nil unless collect_direct_enabled? && arm[:class] == 'Array' && args.size == 1
    return nil unless core_body_is?(arm[:target], 'Enumerable', 'collect') && array_each_core?

    "r#{d} = bc2cpp_ary_collect(M, #{recv}, #{args.first});"
  end

  def emit_collect_direct_helper(compiled)
    compiled.any? { |m| m[:code].include?('bc2cpp_ary_collect(') } ? HELPER : ''
  end

  private

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

  # Does the def that starts at the body's first line read as COLLECT_DIRECT_BODIES says, blank lines and
  # indentation aside?
  def core_def_text_matches?(definition, owner)
    expected = COLLECT_DIRECT_BODIES[[owner, definition.name]]
    irep = @ireps[definition.irep]
    return false unless expected && irep&.file

    line = irep.instructions&.first&.lineno
    text = line && SourceText.read(irep.file, 'COLLECT_DIRECT')
    return false unless text

    lines = text.lines.drop(line - 1)
    indent = lines.first.to_s[/\A */]
    stop = lines.index { |l| l.chomp == "#{indent}end" }
    stop && normalize_def(lines[0..stop].join) == normalize_def(expected)
  end

  def normalize_def(text)
    text.lines.map(&:strip).reject(&:empty?).join("\n")
  end
end

CodeGen.prepend(CollectDirect)
