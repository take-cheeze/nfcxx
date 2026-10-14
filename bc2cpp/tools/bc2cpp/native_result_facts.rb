# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# NATIVE_RESULT_FACTS (ADR 0302): what a call that returns from an RGSS native hands back, per exact
# receiver class. A fact pins the registration's callee text and the delegation chain down to the
# function whose `return`s decide the kind; scripts/bc2cpp/native_result_facts_check.rb re-audits both.
# The kind of each fact is declared in sig/native/rgss_results.rbs, not here (see NativeResultFacts.kind).
# Kinds: :fixnum (mrb_fixnum_value), :float (mrb_float_value), a class name (mrb_obj_new of that constant).
# Left out on purpose, as not one class on every path: Viewport#rect/#ox/#oy (an unset ivar reads nil),
# Window/Plane readers, and setters and drawing calls (they return self, which no bytecode reads).
module NativeResultFacts
  Fact = Struct.new(:callee, :chain)

  def self.accessor(function, chain = [function])
    Fact.new(function, chain)
  end

  def self.rect_lambda(function)
    Fact.new("[](mrb_state* M, V self) { return rgss::#{function}(M, self); }", [function])
  end

  def self.component(owner, field)
    Fact.new("component_get<#{owner}, &#{owner}::#{field}>", ['component_get'])
  end

  FACTS = {
    'RGSS::Bitmap' => {
      'width' => accessor('bmp_width'),
      'height' => accessor('bmp_height'),
      'rect' => accessor('bmp_rect'),
      'text_size' => accessor('bmp_text_size', %w[bmp_text_size bmp_text_size_native_body bmp_text_size_body])
    },
    'RGSS::Rect' => {
      'x' => rect_lambda('rect_x_direct'),
      'y' => rect_lambda('rect_y_direct'),
      'width' => rect_lambda('rect_width_direct'),
      'height' => rect_lambda('rect_height_direct')
    },
    'RGSS::Color' => {
      'red' => component('Color', 'red'),
      'green' => component('Color', 'green'),
      'blue' => component('Color', 'blue'),
      'alpha' => component('Color', 'alpha')
    },
    'RGSS::Tone' => {
      'red' => component('Tone', 'red'),
      'green' => component('Tone', 'green'),
      'blue' => component('Tone', 'blue'),
      'gray' => component('Tone', 'gray')
    }
  }.freeze

  KINDS = NativeCoreResultSigs.load_kinds(NativeCoreResultSigs::RGSS_PATH, scalars: true, classes: %w[RGSS::Rect]).freeze
  # The kinds and the facts describe the same (owner, name) pairs; a mismatch is a broken table, not a silent gap.
  unless KINDS.transform_values(&:keys).values.flatten.sort == FACTS.transform_values(&:keys).values.flatten.sort &&
         KINDS.keys.sort == FACTS.keys.sort
    raise 'bc2cpp: sig/native/rgss_results.rbs and NATIVE_RESULT_FACTS name different (owner, method) pairs'
  end

  module_function

  # :fixnum, :float, a class name, or nil when nothing is declared for `name` on `owner`.
  def kind(name, owner)
    KINDS.dig(owner, name)
  end
end
