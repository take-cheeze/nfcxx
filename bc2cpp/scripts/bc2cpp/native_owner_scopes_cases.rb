# frozen_string_literal: true

require_relative '../../tools/bc2cpp/native_owner_map'

module NativeOwnerScopesCases
  def self.run(check)
    first = <<~'CPP'
      void install(RClass *shared) {
        RClass *klass = mrb_class_get(M, "Inner");
        const char *text = "\" } {";
        char brace = '{';
        if (ready) { use(text); }
      }
    CPP
    second = <<~'CPP'
      void other() {
        RClass *klass = mrb_class_get(M, "Other");
      }
    CPP
    vars = { 'shared' => 'Shared', 'klass' => 'File' }
    body = first + second
    wrappers = [body, "namespace N {\n#{body}}", "extern \"C\" {\n#{body}}",
                "namespace Outer { namespace Inner { extern \"C\" {\n#{body}}}}"]
    ['', "/* 雪é😀 */\n"].each do |prefix|
      wrappers.each_with_index do |wrapped, index|
        source = prefix + wrapped
        scopes = NativeOwnerMap.block_scopes(source, vars)
        expected = [first, second].map { |function| function[function.index('{')..function.rindex('}')] }
        check.call("character offsets and literal/nested braces: prefix #{prefix.length}, wrapper #{index}",
                   scopes.map { |from, to, _scope| source[from..to] } == expected)
        check.call("local owners and parameters: prefix #{prefix.length}, wrapper #{index}",
                   scopes.map { |_, _, scope| [scope['klass'], scope['shared']] } ==
                     [%w[Inner Shared], %w[Other Shared]] && vars['klass'] == 'File')
      end
    end
    check.call('unmatched closing braces do not become scopes', NativeOwnerMap.block_scopes("} #{first} }", vars).size == 1)
    check.call('an unclosed function does not become a scope', NativeOwnerMap.block_scopes('void f() {', vars).empty?)
    check.call('an unclosed namespace does not expose inner scopes',
               NativeOwnerMap.block_scopes("namespace N { #{first}", vars).empty?)
  end
end
