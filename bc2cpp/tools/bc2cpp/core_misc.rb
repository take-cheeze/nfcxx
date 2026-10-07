# frozen_string_literal: true

require 'set'
require_relative 'core_mixins'

# CORE_MISC (docs/adr/0367): the core definitions of `%` and `-@` that bc2cpp_slow_mod and bc2cpp_slow_neg call
# directly (patches/mruby-expose-misc-bodies.patch) or mirror. Each is named by owner, file and body, and an arm is
# emitted only while the build's own sources still say exactly that; a tree without the patch fails the wrapper
# pins below, so the helper keeps its by-name body. scripts/bc2cpp_numeric_slow_check.rb runs the model against
# the real 3rd/mruby and against trees that stop matching it.
module CoreMisc
  Ruby = Struct.new(:owner, :file, :body, keyword_init: true)
  # `function` is the registered wrapper, `wrapper` its body without whitespace (it calls the exported impl).
  Native = Struct.new(:owner, :function, :file, :wrapper, keyword_init: true)

  SPECS = {
    '-@' => {
      ruby: Ruby.new(owner: 'Numeric', file: 'mrblib/numeric.rb',
                     body: CoreMixins.normalize(["def -@\n", "0 - self\n", "end\n"])),
      natives: [Native.new(owner: 'String', function: 'str_uminus', file: 'mruby-string-ext/src/string.c',
                           wrapper: '{returnmrb_str_uminus_impl(mrb,str);}')]
    },
    '%' => {
      ruby: Ruby.new(owner: 'String', file: 'mruby-sprintf/mrblib/string.rb',
                     body: CoreMixins.normalize(["def %(args)\n", "if args.is_a? Array\n", "sprintf(self, *args)\n",
                                                 "else\n", "sprintf(self, args)\n", "end\n", "end\n"])),
      natives: [Native.new(owner: 'Integer', function: 'int_mod', file: 'src/numeric.c',
                           wrapper: '{returnmrb_int_mod_impl(mrb,x,mrb_get_arg1(mrb));}'),
                Native.new(owner: 'Float', function: 'flo_mod', file: 'src/numeric.c',
                           wrapper: '{returnmrb_flo_mod_impl(mrb,x,mrb_get_arg1(mrb));}')]
    }
  }.freeze

  # The Ruby definer is optional for `%` (String#% is the sprintf gem's, absent from a build without it) and
  # required for `-@` (Numeric#-@ is mruby's own mrblib); a native owner is optional too (a gem or MRB_NO_FLOAT).
  RUBY_OPTIONAL = { '-@' => false, '%' => true }.freeze

  # What the String arm of `%` stands on besides String#% itself (sprintf.rb): Kernel#is_a? and Kernel#sprintf, each a
  # single native definer, and the forwarding function the patch adds.
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

  # The owners (simple class names) whose body bc2cpp may run directly for `op`, or nil when the sources do not match
  # the model. +ruby_paths+: the build's Ruby sources; +registrations+: Answers#registrations; +opaque+: its
  # opaque_owners. Neither a second Ruby definer, nor a registration the model does not list, may exist.
  def self.verified(op, ruby_paths, registrations, opaque)
    spec = SPECS[op]
    return nil if spec.nil? || ruby_paths.nil? || registrations.nil? || opaque.nil?
    return nil unless opaque.fetch(op, []).empty?

    owners = Set.new
    return nil unless verify_ruby(op, spec[:ruby], ruby_paths, owners)

    entries = registrations.fetch(op, [])
    return nil unless entries.all? { |e| spec[:natives].any? { |n| native_match?(n, e) } }

    spec[:natives].each do |native|
      found = entries.select { |e| native_match?(native, e) }
      next if found.empty?
      return nil unless found.one? && native_wrapper?(native, found.first)

      owners << native.owner
    end
    owners
  end

  def self.native_match?(native, entry)
    entry[:owner]&.fetch(:class_name, nil) == native.owner && entry[:function] == native.function &&
      CoreMixins.suffix?(entry[:path], native.file)
  end

  def self.native_wrapper?(native, entry)
    function_body(File.read(entry[:path], encoding: 'BINARY'), native.function) == native.wrapper
  end

  # Exactly one def of `op` in the Ruby sources, with the model's body, owner and file; a def of another owner or an
  # alias turns it off. `optional` lets the def be absent.
  def self.verify_ruby(op, model, ruby_paths, owners)
    found = ruby_paths.flat_map { |path| CoreMixins.definers_in(path, File.read(path, encoding: 'UTF-8'), op) }
    return RUBY_OPTIONAL.fetch(op) if found.empty?

    primary = found.select { |d| d.owner == model.owner && CoreMixins.suffix?(d.path, model.file) && !d.alias_only }
    return false unless found.size == 1 && primary.one? && primary.first.body == model.body

    owners << model.owner
    true
  end

  # The String arm of `%` calls `mrb_str_format_impl` and mirrors String#%'s `is_a?`/`sprintf` calls as direct C, so
  # Kernel's two natives and the patch's forwarder must be what the sources say. `registrations` and `opaque` as
  # above; `native_paths` every native source of the build (sprintf is registered by mrb_define_module_function_id,
  # which the registration scan does not read, so its file is pinned by text).
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
