# frozen_string_literal: true

require 'set'
require_relative 'native_names'

# NATIVE_DIRECT (docs/adr/0253): name -> RGSS class -> frame-independent entry
# point in include/rgss_construct.hxx, for sends whose native binding
# (mruby-rgss/src/lib.cxx) unpacks mrb_get_args and forwards to that entry.
# The tables here are checked against the entry points and the registrations
# by scripts/bc2cpp_native_direct_check.rb.
module NativeDirect
  # kinds: :int (guarded by mrb_integer_p, passed as mrb_int), :bool
  # (mrb_test, what mrb_get_args "b" does), :value (passed through).
  Entry = Struct.new(:function, :kinds)

  ENTRIES = {
    'x=' => { 'RGSS::Rect' => Entry.new('rect_x_set_direct', %i[int]),
              'RGSS::Sprite' => Entry.new('object_x_set_direct', %i[int]),
              'RGSS::Window' => Entry.new('object_x_set_direct', %i[int]) },
    'y=' => { 'RGSS::Rect' => Entry.new('rect_y_set_direct', %i[int]),
              'RGSS::Sprite' => Entry.new('object_y_set_direct', %i[int]),
              'RGSS::Window' => Entry.new('object_y_set_direct', %i[int]) },
    'width=' => { 'RGSS::Rect' => Entry.new('rect_width_set_direct', %i[int]),
                  'RGSS::Window' => Entry.new('window_width_set_direct', %i[int]) },
    'height=' => { 'RGSS::Rect' => Entry.new('rect_height_set_direct', %i[int]),
                   'RGSS::Window' => Entry.new('window_height_set_direct', %i[int]) },
    'z=' => { 'RGSS::Viewport' => Entry.new('object_z_set_direct', %i[int]),
              'RGSS::Sprite' => Entry.new('object_z_set_direct', %i[int]),
              'RGSS::Plane' => Entry.new('object_z_set_direct', %i[int]),
              'RGSS::Window' => Entry.new('object_z_set_direct', %i[int]),
              'RGSS::Tilemap' => Entry.new('tilemap_z_set_direct', %i[int]) },
    'visible=' => { 'RGSS::Viewport' => Entry.new('object_visible_set_direct', %i[bool]),
                    'RGSS::Sprite' => Entry.new('object_visible_set_direct', %i[bool]),
                    'RGSS::Plane' => Entry.new('object_visible_set_direct', %i[bool]),
                    'RGSS::Window' => Entry.new('object_visible_set_direct', %i[bool]),
                    'RGSS::Tilemap' => Entry.new('tilemap_visible_set_direct', %i[bool]) },
    'visible' => { 'RGSS::Tilemap' => Entry.new('visible_direct', []),
                   'RGSS::Window' => Entry.new('visible_direct', []) },
    'contents=' => { 'RGSS::Window' => Entry.new('window_contents_set_direct', %i[value]) },
    'windowskin=' => { 'RGSS::Window' => Entry.new('window_windowskin_set_direct', %i[value]) },
    'cursor_rect=' => { 'RGSS::Window' => Entry.new('window_cursor_rect_set_direct', %i[value]) },
    'active=' => { 'RGSS::Window' => Entry.new('window_active_set_direct', %i[bool]) },
    'pause=' => { 'RGSS::Window' => Entry.new('window_pause_set_direct', %i[bool]) },
    'color=' => { 'RGSS::Viewport' => Entry.new('viewport_color_set_direct', %i[value]),
                  'RGSS::Sprite' => Entry.new('sprite_color_set_direct', %i[value]),
                  'RGSS::Plane' => Entry.new('plane_color_set_direct', %i[value]) },
    'color' => { 'RGSS::Viewport' => Entry.new('viewport_color_direct', []) },
    'tone' => { 'RGSS::Viewport' => Entry.new('viewport_tone_direct', []),
                'RGSS::Window' => Entry.new('window_tone_direct', []) },
    'flash' => { 'RGSS::Viewport' => Entry.new('viewport_flash_direct', %i[value int]),
                 'RGSS::Sprite' => Entry.new('sprite_flash_direct', %i[value int]) }
  }.freeze

  C_STRING_OR_CHAR = %r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m

  @registrations = {}

  module_function

  def strip_comments(text)
    text.gsub(C_STRING_OR_CHAR) { |tok| tok.start_with?('/') ? ' ' : tok }
  end

  # { 'c_var' => 'RGSS::Rect' } for the classes and modules a file defines,
  # including an `RClass* m` parameter whose callers all pass the same module.
  # The table is by variable name, not scope: a name with several definitions
  # is kept only when they all resolve to one owner, which makes its
  # registrations unproven rather than attributed to the wrong class.
  def class_variables(text)
    defs = Hash.new { |h, k| h[k] = [] }
    text.scan(/RClass\s*\*\s*(\w+)\s*=\s*mrb_define_(module|class)(_under)?\s*\(([^;]*?)\)\s*;/m) do |var, _kind, under, args|
      parts = args.split(',').map(&:strip)
      defs[var] << (under ? [:under, parts[1], parts[2][/"(\w+)"/, 1]] : [:top, parts[1][/"(\w+)"/, 1]])
    end
    text.scan(/(\w+)\s*\(\s*mrb_state\s*\*\s*\w+\s*,\s*RClass\s*\*\s*(\w+)\s*\)\s*\{/) do |func, param|
      callers = text.scan(/\b#{Regexp.escape(func)}\s*\(\s*\w+\s*,\s*(\w+)\s*\)\s*;/).flatten
      defs[param] << [:param, callers]
    end
    owners = {}
    resolve = lambda do |definition|
      case definition.first
      when :top then definition[1]
      when :under
        parent = owners[definition[1]]
        parent && definition[2] ? "#{parent}::#{definition[2]}" : nil
      else
        found = definition[1].map { |arg| owners[arg] }.uniq
        found.size == 1 ? found.first : nil
      end
    end
    # A parameter that is only ever handed the variable it shadows (`m`) adds
    # no owner of its own, so an unresolved parameter definition is ignored
    # while the fixed point settles and an unresolved class definition is not.
    4.times do
      defs.each do |var, list|
        found = list.reject { |d| d.first == :param && resolve.call(d).nil? }.map { |d| resolve.call(d) }.uniq
        owners[var] = found.size == 1 ? found.first : nil
      end
    end
    owners
  end

  # Every "name" registration in `path` as [owner, kind]; owner is nil when
  # the class expression is not a variable defined in the same file. Class
  # methods and module functions register on "<owner>.singleton".
  # { name => { owners: [..], literals: n } } per file, memoized.
  def file_registrations(path)
    @registrations[path] ||= begin
      text = strip_comments(File.binread(path).force_encoding('UTF-8'))
      owners = class_variables(text)
      table = Hash.new { |h, k| h[k] = { owners: [], literals: 0 } }
      text.scan(/"((?:[^"\\\n]|\\.)*)"/) { |(lit)| table[lit][:literals] += 1 }
      text.scan(MRB_SYM_TOKEN_RE) { |macro, tok| table[resolve_mrb_sym_token(macro, tok)][:literals] += 1 }
      text.scan(/\bmrb_define_(\w+)\s*\(\s*\w+\s*,\s*(\w+)\s*,\s*"((?:[^"\\\n]|\\.)*)"/) do |kind, var, name|
        owner = owners[var]
        owner = "#{owner}.singleton" if owner && kind != 'method' && kind != 'private_method'
        table[name][:owners] << owner
      end
      table.default_proc = nil
      table
    end
  end

  # The classes that register `name` in `paths`, or nil when that cannot be
  # proven: a spelling of the name that is not a parsed registration on a
  # class variable of the same file means some registration was missed.
  def registered_owners(name, paths)
    owners = Set.new
    Array(paths).each do |path|
      entry = file_registrations(path)[name]
      next unless entry
      return nil if entry[:literals] != entry[:owners].size || entry[:owners].any?(&:nil?)

      owners.merge(entry[:owners])
    end
    owners
  end
end
