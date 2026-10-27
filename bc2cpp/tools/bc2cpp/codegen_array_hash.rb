# frozen_string_literal: true

require_relative 'codegen_collect_direct'
require_relative 'source_text'

# ARRAY_HASH_FIXNUM: the compiled Enumerable#hash starts with a native loop for an exact Array whose elements are all
# Fixnums, so a Hash keyed by `[a, b]` (optcarrot's PPU#setup_lut) no longer pays three by-name sends per element
# (`__method_recursive?`, `e.hash`, `__update_hash`). The loop computes what those C functions compute, so the value
# is the interpreter's. docs/bc2cpp-array-hash.md has the equivalence and the conditions.
module ArrayHashFixnum
  ENUM_HASH_BODY = <<~RUBY
    def hash
      if __method_recursive?(:hash)
        # Recursion detected, return a fixed value to break the loop
        return 0
      end
      h = 12347
      i = 0
      self.each do |e|
        h = __update_hash(h, i, e.hash)
        i += 1
      end
      h
    end
  RUBY

  # The three sends, by their C bodies: kernel.c mrb_obj_method_recursive_p (scanning from below its own frame and
  # the caller's, so from ci - 1 here), numeric.c int_hash, enum.c enum_update_hash. Elements are checked first:
  # nothing in the loop can run Ruby, so the receiver cannot change under it.
  HELPER = <<~CPP
    extern "C" uint32_t mrb_byte_hash(const uint8_t*, mrb_int);
    static bool bc2cpp_ary_fixnum_hash(mrb_state* M, mrb_value self, mrb_sym hash_sym, mrb_value* out) {
      if (!mrb_array_p(self) || mrb_obj_ptr(self)->c != M->array_class) return false;
      struct RArray* a = mrb_ary_ptr(self);
      const mrb_value* p = ARY_PTR(a);
      mrb_int n = ARY_LEN(a);
      for (mrb_int i = 0; i < n; ++i) {
        if (!mrb_fixnum_p(p[i])) return false;
      }
      for (const mrb_callinfo* ci = M->c->ci - 1; ci >= M->c->cibase; --ci) {
        if (ci->mid == hash_sym && mrb_obj_eq(M, self, ci->stack[0])) {
          *out = mrb_fixnum_value(0);
          return true;
        }
      }
      mrb_int hash = 12347;
      for (mrb_int i = 0; i < n; ++i) {
        mrb_int v = mrb_integer(p[i]);
        mrb_int hv = (mrb_int)mrb_byte_hash((uint8_t*)&v, sizeof(v));
        hash ^= ((uint32_t)hv << (i % 16));
      }
      *out = mrb_int_value(M, hash);
      return true;
    }

  CPP

  # The sends the loop replaces must reach these C bodies from an Array (or a Fixnum, for `hash`).
  NATIVE_SENDS = { 'hash' => 'Integer', '__update_hash' => 'Array', '__method_recursive?' => 'Array' }.freeze

  def array_hash_fixnum_enabled?
    ENV['BC2CPP_ARRAY_HASH'] != '0'
  end

  # The prologue of the compiled Enumerable#hash, or ''.
  def array_hash_fixnum_prologue(definition)
    return '' unless array_hash_fixnum_enabled? && definition.core && definition.owner == 'Enumerable' &&
                     definition.name == 'hash' && array_hash_fixnum_world?(definition)

    "  // ARRAY_HASH_FIXNUM -- an exact Array of Fixnums hashes natively (docs/bc2cpp-array-hash.md)\n" \
      "  { mrb_value bc2cpp_ary_h; " \
      "if (bc2cpp_ary_fixnum_hash(M, self, mrb_intern_lit(M, \"hash\"), &bc2cpp_ary_h)) return bc2cpp_ary_h; }\n"
  end

  def emit_array_hash_helper(compiled)
    compiled.any? { |m| m[:code].include?('bc2cpp_ary_fixnum_hash(') } ? HELPER : ''
  end

  private

  def array_hash_fixnum_world?(definition)
    world = @closed_world || @core_program_world
    memo = (@array_hash_fixnum_world ||= {}.compare_by_identity)
    return memo[world] if memo.key?(world)

    installed = symbol_installed_names
    memo[world] =
      !world.nil? && !installed.nil? &&
      (NATIVE_SENDS.keys + %w[each]).none? { |name| installed.include?(name) || devirt_blocked_name?(name) } &&
      NATIVE_SENDS.all? { |name, owner| builtin_class_send_safe?(name, [owner]) } &&
      array_each_core? && enum_hash_text_matches?(definition)
  end

  # Does the def at the body's first line read as ENUM_HASH_BODY, blank lines and indentation aside?
  def enum_hash_text_matches?(definition)
    irep = @ireps[definition.irep]
    line = irep&.file && irep.instructions&.first&.lineno
    text = line && SourceText.read(irep.file, 'ARRAY_HASH_FIXNUM')
    return false unless text

    lines = text.lines.drop(line - 1)
    indent = lines.first.to_s[/\A */]
    stop = lines.index { |l| l.chomp == "#{indent}end" }
    stop && normalize_def(lines[0..stop].join) == normalize_def(ENUM_HASH_BODY)
  end
end

CodeGen.prepend(ArrayHashFixnum)
