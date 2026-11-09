# frozen_string_literal: true

require 'set'
require_relative 'core_mixins'

# CORE_MISC: the Kernel natives and forwarding function that the String arm of `%` once mirrored (is_a? and sprintf,
# sprintf.rb). The `%` and `-@` entries are gone, so their helpers run the by-name dispatch and nothing
# compiled reads the pins below. `function_body` is also read by codegen_numeric_slow_zero.rb.
module CoreMisc
  # Kernel#is_a? and Kernel#sprintf, each a single native definer, and the forwarding function the patch adds.
  KERNEL_PINS = {
    'is_a?' => { file: 'src/kernel.c', function: 'mrb_obj_is_kind_of_m',
                 body: '{structRClass*c;mrb_get_args(mrb,"c",&c);returnmrb_bool_value(mrb_obj_is_kind_of(mrb,self,c));}' },
    'sprintf' => { file: 'mruby-sprintf/src/sprintf.c', function: 'mrb_f_sprintf',
                   body: '{mrb_intargc;constmrb_value*argv;mrb_get_args(mrb,"*",&argv,&argc);if(argc<=0){' \
                         'mrb_raise(mrb,E_ARGUMENT_ERROR,"toofewarguments");returnmrb_nil_value();}else{' \
                         'returnmrb_str_format(mrb,argc-1,argv+1,argv[0]);}}' }
  }.freeze
  FORMAT_IMPL = { file: 'mruby-sprintf/src/sprintf.c', function: 'mrb_str_format_impl',
                  body: '{returnmrb_str_format(mrb,argc,argv,fmt);}' }.freeze

  # Body of C function `name` in `text` (whitespace removed), or nil.
  def self.function_body(text, name)
    text[/^#{Regexp.escape(name)}\(mrb_state\s*\*mrb[^)]*\)\n\{.*?^\}\n/m]&.then { |body| body.sub(/\A[^{]*/, '').gsub(/\s+/, '') }
  end

  # The Kernel pins hold in the build's sources: each native is the one definer, registered once from its file, and
  # the forwarder is the patch's. +registrations+: Answers#registrations; +opaque+: its opaque_owners; +native_paths+:
  # every native source of the build (sprintf is registered by mrb_define_module_function_id, which the registration
  # scan does not read, so its file is pinned by text).
  def self.format_pins?(registrations, opaque, native_paths)
    kernel = KERNEL_PINS.all? do |name, pin|
      next false unless opaque.fetch(name, []).empty?

      path = native_paths.find { |p| CoreMixins.suffix?(p, pin[:file]) }
      next false if path.nil?

      text = File.read(path, encoding: 'BINARY')
      next false unless function_body(text, pin[:function]) == pin[:body]
      next module_function_once?(text, name) if name == 'sprintf'

      entries = registrations.fetch(name, [])
      entries.size == 1 && entries.first[:function] == pin[:function] && entries.first[:path] == path &&
        entries.first[:owner]&.fetch(:class_name, nil) == 'Kernel'
    end
    return false unless kernel

    path = native_paths.find { |p| CoreMixins.suffix?(p, FORMAT_IMPL[:file]) }
    !path.nil? && function_body(File.read(path, encoding: 'BINARY'), FORMAT_IMPL[:function]) == FORMAT_IMPL[:body]
  end

  def self.module_function_once?(text, name)
    text.scan(/mrb_define_(?:method|module_function)(?:_id)?\s*\([^;]*?(?:MRB_SYM\(#{name}\)|"#{name}")/m).size == 1
  end
end
