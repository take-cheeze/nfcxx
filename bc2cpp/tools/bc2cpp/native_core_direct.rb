# frozen_string_literal: true

require 'set'
require_relative 'irep'
require_relative 'native_names'
require_relative 'native_expression_devirt'

# NATIVE_CORE_DIRECT (docs/adr/0257): exact-builtin-class arms that call a core
# native method's frame-independent body directly, the mruby-core counterpart of
# NativeDirect's RGSS entry points (ADR 0253).
#
# A method is admitted only through a hand-audited entry below. The audit is
# re-run against the real sources on every compile (`audit`): the ROM
# registration must still bind `function` to `name` on `owner` with `aspec`, the
# registered function's body must still be the text the entry was written
# against, and any public API the expression names must still be declared
# MRB_API. An entry that no longer verifies is dropped, never trusted.
module NativeCoreDirect
  # tag/field are the instance type tag and MRB_state class field the guard
  # compares; an Integer is an immediate, so its type tag decides alone.
  OWNERS = {
    'Array' => { guard: 'mrb_array_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->array_class' },
    'String' => { guard: 'mrb_string_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->string_class' },
    'Integer' => { guard: 'mrb_integer_p(%<r>s)' }
  }.freeze

  # A guard that keeps the C wrapper's argument coercion out of the fast path:
  # anything else takes the ordinary send, which raises what the wrapper would.
  ARG_GUARDS = {
    none: nil,
    integer: 'mrb_integer_p(%<a>s)',
    nil_or_string: '(mrb_nil_p(%<a>s) || mrb_string_p(%<a>s))'
  }.freeze

  # `checks` are [function, expected body, :exact | :prefix]; the first is the
  # registered function. Bodies are compared with whitespace and comments removed.
  Entry = Struct.new(:name, :owner, :arity, :arg, :aspec, :expression, :checks, :apis, :helper, keyword_init: true) do
    def function
      checks.first.first
    end

    def guard(recv, argv)
      parts = [format(OWNERS.fetch(owner)[:guard], r: recv)]
      arg_guard = ARG_GUARDS.fetch(arg)
      parts << format(arg_guard, a: argv.first) if arg_guard
      parts.join(' && ')
    end

    def call(recv, argv)
      expression.gsub('recv', recv).gsub('ARG0', argv.first.to_s)
    end
  end

  ENTRIES = [
    Entry.new(name: 'join', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_ary_join(M, recv, mrb_nil_value())',
              apis: [%w[mruby/array.h mrb_ary_join]],
              checks: [['mrb_ary_join_m', <<~C, :exact]]),
                mrb_value sep = mrb_nil_value();
                mrb_get_args(mrb, "|S!", &sep);
                return mrb_ary_join(mrb, ary, sep);
              C
    Entry.new(name: 'join', owner: 'Array', arity: 1, arg: :nil_or_string, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_ary_join(M, recv, ARG0)',
              apis: [%w[mruby/array.h mrb_ary_join]],
              checks: [['mrb_ary_join_m', <<~C, :exact]]),
                mrb_value sep = mrb_nil_value();
                mrb_get_args(mrb, "|S!", &sep);
                return mrb_ary_join(mrb, ary, sep);
              C
    Entry.new(name: 'shift', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_ary_shift(M, recv)',
              apis: [%w[mruby/array.h mrb_ary_shift]],
              checks: [['mrb_ary_shift_m', <<~C, :prefix]]),
                if (mrb_get_argc(mrb) == 0) {
                  return mrb_ary_shift(mrb, self);
                }
              C
    # Integer#inspect is int_to_s registered a second time; with no argument the
    # base is 10 and the body is mrb_integer_to_str.
    Entry.new(name: 'inspect', owner: 'Integer', arity: 0, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'mrb_integer_to_str(M, recv, 10)',
              apis: [%w[mruby/numeric.h mrb_integer_to_str]],
              checks: [['int_to_s', <<~C, :exact]]),
                mrb_int base;
                if (mrb_get_argc(mrb) > 0) {
                  base = mrb_integer(mrb_get_arg1(mrb));
                }
                else {
                  base = 10;
                }
                return mrb_integer_to_str(mrb, self, base);
              C
    # The three below have static bodies, so the call is a mirror in
    # emit_native_core_helpers; its behavior is pinned by these bodies.
    Entry.new(name: 'compact', owner: 'Array', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'bc2cpp_ary_compact(M, recv)', helper: 'bc2cpp_ary_compact',
              apis: [],
              checks: [['ary_compact', <<~C, :exact],
                mrb_value ary = mrb_ary_dup(mrb, self);
                ary_compact_bang(mrb, ary);
                return ary;
              C
                       ['ary_compact_bang', <<~C, :exact]]),
                struct RArray *a = mrb_ary_ptr(self);
                mrb_int i, j = 0;
                mrb_int len = ARY_LEN(a);
                mrb_ary_modify(mrb, a);
                mrb_value *ptr = RARRAY_PTR(self);
                for (i = 0; i < len; i++) {
                  if (!mrb_nil_p(ptr[i])) {
                    if (i != j) ptr[j] = ptr[i];
                    j++;
                  }
                }
                if (i == j) return mrb_nil_value();
                ARY_SET_LEN(RARRAY(self), j);
                return self;
              C
    Entry.new(name: 'index', owner: 'Array', arity: 1, arg: :none, aspec: 'MRB_ARGS_OPT(1)',
              expression: 'bc2cpp_ary_index(M, recv, ARG0)', helper: 'bc2cpp_ary_index',
              apis: [],
              checks: [['mrb_ary_index_m', <<~C, :exact]]),
                mrb_value obj, blk;
                if (mrb_get_args(mrb, "|o&", &obj, &blk) == 0 && mrb_nil_p(blk)) {
                  return mrb_funcall_id(mrb, self, MRB_SYM(to_enum), 1, mrb_symbol_value(MRB_SYM(index)));
                }
                if (mrb_nil_p(blk)) {
                  for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
                    if (mrb_equal(mrb, RARRAY_PTR(self)[i], obj)) {
                      return mrb_int_value(mrb, i);
                    }
                  }
                }
                else {
                  for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
                    mrb_value eq = mrb_yield(mrb, blk, RARRAY_PTR(self)[i]);
                    if (mrb_test(eq)) {
                      return mrb_int_value(mrb, i);
                    }
                  }
                }
                return mrb_nil_value();
              C
    Entry.new(name: 'bytes', owner: 'String', arity: 0, arg: :none, aspec: 'MRB_ARGS_NONE()',
              expression: 'bc2cpp_str_bytes(M, recv)', helper: 'bc2cpp_str_bytes',
              apis: [],
              checks: [['mrb_str_bytes', <<~C, :exact]])
                struct RString *s = mrb_str_ptr(str);
                mrb_value a = mrb_ary_new_capa(mrb, RSTR_LEN(s));
                unsigned char *p = (unsigned char*)(RSTR_PTR(s)), *pend = p + RSTR_LEN(s);
                while (p < pend) {
                  mrb_ary_push(mrb, a, mrb_fixnum_value(p[0]));
                  p++;
                }
                return a;
              C
  ].freeze

  # The C text of each helper, emitted once per output that calls it.
  HELPERS = {
    'bc2cpp_ary_compact' => <<~CPP,
      static inline mrb_value bc2cpp_ary_compact(mrb_state* M, mrb_value self) {
        mrb_value ary = mrb_ary_new_capa(M, RARRAY_LEN(self));
        for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
          if (!mrb_nil_p(RARRAY_PTR(self)[i])) mrb_ary_push(M, ary, RARRAY_PTR(self)[i]);
        }
        return ary;
      }
    CPP
    'bc2cpp_ary_index' => <<~CPP,
      static inline mrb_value bc2cpp_ary_index(mrb_state* M, mrb_value self, mrb_value obj) {
        for (mrb_int i = 0; i < RARRAY_LEN(self); i++) {
          if (mrb_equal(M, RARRAY_PTR(self)[i], obj)) return mrb_int_value(M, i);
        }
        return mrb_nil_value();
      }
    CPP
    'bc2cpp_str_bytes' => <<~CPP
      static inline mrb_value bc2cpp_str_bytes(mrb_state* M, mrb_value str) {
        mrb_value a = mrb_ary_new_capa(M, RSTRING_LEN(str));
        for (mrb_int i = 0; i < RSTRING_LEN(str); i++) {
          mrb_ary_push(M, a, mrb_fixnum_value((unsigned char)RSTRING_PTR(str)[i]));
        }
        return a;
      }
    CPP
  }.freeze

  @audits = {}

  module_function

  def normalize(text)
    text.gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ').gsub(/\s+/, '')
  end

  def mruby_include_dir(paths)
    root = Array(paths).filter_map { |path| path[%r{\A(.+/3rd/mruby)/}, 1] }.first
    dir = root && File.join(root, 'include')
    dir if dir && File.directory?(dir)
  end

  # The body of the function named `function` in `path`, or nil.
  def function_body(path, function)
    source = NativeExpressionDevirt.read_source(path)
    pattern = /\b#{Regexp.escape(function)}\s*\(\s*mrb_state\s*\*\s*\w+\s*,\s*mrb_value\s+\w+\s*\)\s*\{/
    match = pattern.match(source)
    return unless match

    NativeExpressionDevirt.brace_body(source, match.end(0) - 1).first
  end

  # { entry => nil | failure reason } for every ENTRIES row against `paths`.
  def audit(paths)
    files = Array(paths).select { |path| File.file?(path) }
    key = files.map { |path| stat = File.stat(path); [path, stat.mtime, stat.size] }
    include_dir = mruby_include_dir(files)
    key += ENTRIES.flat_map(&:apis).map(&:first).uniq.map do |header|
      path = include_dir && File.join(include_dir, header)
      stat = path && File.file?(path) && File.stat(path)
      [path, stat && stat.mtime, stat && stat.size]
    end
    @audits.fetch(key) do
      @audits.clear
      @audits[key] = audit_files(files)
    end
  end

  def audit_files(files)
    registrations, opaque_owners = NativeExpressionDevirt.class_registrations(files)
    include_dir = mruby_include_dir(files)
    ENTRIES.to_h { |entry| [entry, audit_entry(entry, registrations, opaque_owners, include_dir)] }
  end

  def audit_entry(entry, registrations, opaque_owners, include_dir)
    return 'no mruby core include directory' unless include_dir
    unattributed = opaque_owners.fetch(entry.name, []).any? { |owner| owner.nil? || owner == entry.owner }
    return 'spelled by an unattributed native registration' if unattributed

    matches = registrations.fetch(entry.name, []).select do |registration|
      registration[:owner] && registration[:owner][:class_name] == entry.owner
    end
    return "expected exactly one #{entry.owner}##{entry.name} registration, found #{matches.size}" unless matches.one?

    registration = matches.first
    unless registration[:function] == entry.function && registration[:aspec] == entry.aspec
      return "#{entry.owner}##{entry.name} is registered as #{registration[:function]} #{registration[:aspec]}"
    end

    entry.checks.each do |function, expected, mode|
      path = registration[:path]
      body = function_body(path, function)
      return "#{function} not found in #{File.basename(path)}" unless body

      actual = normalize(body)
      wanted = normalize(expected)
      ok = mode == :exact ? actual == wanted : actual.start_with?(wanted)
      return "#{function} no longer matches the audited body" unless ok
    end
    entry.apis.each do |header, function|
      text = File.read(File.join(include_dir, header), encoding: 'UTF-8')
      return "#{function} is not declared MRB_API in #{header}" unless text.match?(/\bMRB_API\s+\w[\w\s*]*\b#{function}\s*\(/)
    end
    nil
  end

  def verified?(paths, entry)
    audit(paths).fetch(entry).nil?
  end
end
