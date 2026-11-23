# frozen_string_literal: true

require 'stringio'
require_relative 'presym_spelling'
require_relative 'symbol_cache'

# COMPACT_LABELS: a declaration-check or guard-violation site's "Owner#name..." label is a row of a per-gem table (owner
# and tail as shared strings, the name as its presym id) instead of a string per method. The `_at` helpers rebuild the
# text and call the string form, so the message and the log line are the same bytes; a label that does not parse keeps
# its string. A real gem build compacts, a fixture and the proof's generation do not; BC2CPP_COMPACT_LABELS=1/0 forces.
module LabelTable
  AT = "/* BC2CPP_LABEL_TABLE */\n"
  DECLARED = /\bbc2cpp_declared_(return|param|keyword|ivar)_violation\(M, ([^;"\n]*?), "((?:[^"\\\n]|\\.)*)", /
  GUARD = /\bbc2cpp_guard_violation\(M, ([^;"\n]*?), (\d+), "((?:[^"\\\n]|\\.)*)", /
  OWNER = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*(?:\.singleton)?\z/
  TAIL = /\A(?:[ \[][^"\\]*)?\z/
  # The name field's flag for a name presym cannot spell: the low 15 bits index bc2cpp_label_texts.
  TEXT_NAME = 0x8000

  module_function

  # +real+: the run is a real gem build.
  def enabled?(real, env = ENV)
    case env['BC2CPP_COMPACT_LABELS']
    when '1' then true
    when '0' then false
    else real
    end
  end

  # [owner, name, tail] of a label, or nil: the longest name prefix presym can spell whose rest is a tail.
  def parse(label)
    owner, rest = label.split('#', 2)
    return nil unless rest && owner.match?(OWNER)

    rest.size.downto(1) do |n|
      name = rest[0, n]
      tail = rest[n..]
      return [owner, name, tail] if PresymSpelling.symbol(name) && tail.match?(TAIL)
    end
    nil
  end

  # The table a rewrite fills: texts (owners, tails, names without a presym) and rows, each once.
  class Table
    attr_reader :texts, :rows

    def initialize
      @texts = ['']
      @text_index = { '' => 0 }
      @rows = []
      @row_index = {}
      @guard = false
    end

    def guard_used! = @guard = true
    def guard_used? = @guard

    def text(str)
      @text_index[str] ||= (@texts << str).size - 1
    end

    # The row of `label`, or nil when it does not parse.
    def row(label)
      parsed = LabelTable.parse(label)
      return nil unless parsed

      owner, name, tail = parsed
      field = SymbolCache.presym_macro("\"#{name}\"")
      unless field
        index = text(name)
        return nil if index >= TEXT_NAME

        field = "0x8000u | #{index}u" # TEXT_NAME
      end
      entry = [text(owner), field, text(tail)]
      @row_index[entry] ||= (@rows << entry).size - 1
    end
  end

  # `text` with the label of every violation site after AT a table row, and AT replaced by the table and its helpers.
  def rewrite(text, enabled)
    at = text.index(AT)
    return text unless at
    return text.sub(AT, '') unless enabled

    head = text[0...at]
    body = text[(at + AT.size)..]
    table = Table.new
    body = body.gsub(DECLARED) do
      kind, value, label = Regexp.last_match.captures
      row = table.row(label)
      row ? "bc2cpp_declared_#{kind}_violation_at(M, #{value}, #{row}, " : Regexp.last_match(0)
    end
    body = body.gsub(GUARD) do
      recv, index, site = Regexp.last_match.captures
      row = table.row(site)
      next Regexp.last_match(0) unless row

      table.guard_used!
      "bc2cpp_guard_violation(M, #{recv}, #{index}, Bc2cppLabel{#{row}}, "
    end
    head + emit(table) + body
  end

  def c_string(str)
    "\"#{str.gsub(/[^ -~]|["\\]/) { |c| c.bytes.map { |b| format('\\%03o', b) }.join }}\""
  end

  # The table and the helpers; nothing when no site became a row.
  def emit(table)
    return '' if table.rows.empty?

    rows = table.rows.map { |owner, name, tail| "{#{owner}, #{name}, #{tail}}" }.join(', ')
    <<~CPP + (table.guard_used? ? GUARD_HELPER : '')
      // COMPACT_LABELS (label_table.rb): row -> "Owner#name" + tail, built only when a violation fires.
      static_assert(MRB_PRESYM_MAX < #{TEXT_NAME}, "COMPACT_LABELS: a presym id fits a label row's name field");
      struct Bc2cppLabel { uint16_t row; };
      struct Bc2cppLabelRow { uint16_t owner, name, tail; };
      static const char* const bc2cpp_label_texts[#{table.texts.size}] = {
      #{table.texts.map { |t| "  #{c_string(t)}," }.join("\n")}
      };
      static const Bc2cppLabelRow bc2cpp_label_rows[#{table.rows.size}] = { #{rows} };
      // The label's text as a new String's bytes: the String stays in the GC arena of the violation's frame.
      [[maybe_unused, gnu::cold, gnu::noinline]] static const char* bc2cpp_label_cstr(mrb_state* M, uint16_t row) {
        const Bc2cppLabelRow& r = bc2cpp_label_rows[row];
        mrb_value s = mrb_str_new_cstr(M, bc2cpp_label_texts[r.owner]);
        mrb_str_cat_lit(M, s, "#");
        if (r.name & #{TEXT_NAME}u) {
          mrb_str_cat_cstr(M, s, bc2cpp_label_texts[r.name & #{TEXT_NAME - 1}u]);
        } else {
          mrb_int n;
          const char* p = mrb_sym_name_len(M, (mrb_sym)r.name, &n);
          mrb_str_cat(M, s, p, n);
        }
        mrb_str_cat_cstr(M, s, bc2cpp_label_texts[r.tail]);
        return RSTRING_PTR(s);
      }
      [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_return_violation_at(mrb_state* M, mrb_value value, uint16_t method, const char* declared) {
        bc2cpp_declared_return_violation(M, value, bc2cpp_label_cstr(M, method), declared);
      }
      [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_param_violation_at(mrb_state* M, mrb_value value, uint16_t method, int position, const char* declared) {
        bc2cpp_declared_param_violation(M, value, bc2cpp_label_cstr(M, method), position, declared);
      }
      [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_keyword_violation_at(mrb_state* M, mrb_value value, uint16_t method, const char* declared) {
        bc2cpp_declared_keyword_violation(M, value, bc2cpp_label_cstr(M, method), declared);
      }
      [[maybe_unused, noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_declared_ivar_violation_at(mrb_state* M, mrb_value value, uint16_t ivar, const char* declared) {
        bc2cpp_declared_ivar_violation(M, value, bc2cpp_label_cstr(M, ivar), declared);
      }
    CPP
  end

  # GUARD_VIOLATION's entry with the site as a row (symbol_cache.rb): the same text reaches bc2cpp_guard_violation_raise.
  GUARD_HELPER = <<~CPP
    BC2CPP_GUARD_VIOLATION_HEAD static mrb_value bc2cpp_guard_violation(mrb_state* M, mrb_value recv, int i, Bc2cppLabel site, mrb_int argc, ...) {
    #ifdef BC2CPP_GUARD_VIOLATION_DISPATCH
      (void)site;
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
    #else
      (void)argc;
      bc2cpp_guard_violation_raise(M, recv, bc2cpp_sym(M, i), bc2cpp_label_cstr(M, site.row));
    #endif
    }
  CPP

  def capture_stdout(enabled)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      original.write(rewrite(buffer.string, enabled)) unless $!
    end
  end
end
