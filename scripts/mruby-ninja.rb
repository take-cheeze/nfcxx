#!/usr/bin/env ruby
# Generates the ninja build file for mruby, so that mruby can be built without rake. scripts/setup-mruby.sh runs
# `generate`, then ninja. It reads the same inputs as mruby's own rake build: a build config (a MRuby::Build block,
# e.g. scripts/mruby-tool-config.rb) and the mrbgem.rake of each gem in the config's dependency closure. Those
# files are evaluated against the small DSL below instead of rake, and any call this script does not model raises,
# so an unsupported gem fails the generation rather than building wrongly.
#
# The gem closure and its order (lib/mruby/gem.rb: tsort_dependencies), the source lists, the gcc flags
# (tasks/toolchains/gcc.rake), the mrbc sub-build with its own presym pass, and the generated gem_init and mrblib
# sources follow mruby 4.0.0. The presym scanner and header writers are mruby's own lib/mruby/presym.rb.
#
#   ruby scripts/mruby-ninja.rb generate MRUBY_SRC CONFIG OUT   writes OUT/build.ninja and the generated .c files
#   ruby scripts/mruby-ninja.rb presym MRUBY_SRC BUILD_DIR PPP...   the presym pass; ninja runs it, not you
#
# Supported: the gcc toolchain; one host build with libmruby; the mrbc sub-build. Gems: src/*.c, mrblib/**/*.rb,
# tools/<bin>/*.c, and the compiler gem's core/*.c (its build_settings). Not supported: cross builds, C++/ObjC,
# tests, install, and mruby-io's HAL auto-selection (the config must name a HAL gem, as the tool config does).
# mruby-onig-regexp's bundled Onigmo is built by an explicit step (emit_onigmo) rather than by its rake file.

require 'fileutils'
require 'pathname'
require 'shellwords'
require 'tsort'

module MrubyNinja
  # tasks/toolchains/gcc.rake: the C mandatory flags, then the default flags (or CFLAGS, when set).
  C_MANDATORY_FLAGS = %w[-std=gnu99].freeze
  C_DEFAULT_FLAGS = %w[-g -O3 -Wall -Wundef -Werror-implicit-function-declaration -Wwrite-strings].freeze
  C_FLAGS = (C_MANDATORY_FLAGS + (ENV['CFLAGS'] ? Shellwords.split(ENV['CFLAGS']) : C_DEFAULT_FLAGS)).freeze
  PRESYM_EXT = '.pi'
  # Built by the mrbc sub-build, so the host build leaves it out (the summary of mruby's host build does too).
  SUB_BUILD_GEMS = %w[mruby-bin-mrbc].freeze
  # mruby-bin-mrbc's bin links the core archive, not libmruby.
  CORE_LINKED_BINS = %w[mrbc].freeze
  # A gem's build directory, as its mrbgem.rake sees it; the generator substitutes the real one afterwards.
  BUILD_DIR_PLACEHOLDER = '@BUILD_DIR@'
  ONIGMO_VERSION_RE = /\Aonigmo-(\d[\d.]*)\.tar\.gz\z/

  # What a build config may set on a tool (cc, linker, archiver). Anything else raises.
  class Tool
    attr_accessor :command
    attr_reader :defines

    def initialize
      @defines = []
    end
  end

  # The conf that MRuby::Build.new yields. Anything else a config calls raises.
  class Conf
    attr_reader :cc, :linker, :archiver, :gem_entries

    def initialize
      @cc = Tool.new
      @linker = Tool.new
      @archiver = Tool.new
      @gem_entries = []
    end

    def toolchain(name)
      raise "config: toolchain #{name.inspect} is not supported (gcc only)" unless name == :gcc
    end

    def gem(opts)
      if opts.is_a?(Hash) && opts[:core]
        @gem_entries << [:core, opts[:core]]
      elsif opts.is_a?(String)
        @gem_entries << [:path, opts]
      else
        raise "config: gem #{opts.inspect} is not supported"
      end
    end
  end

  # A tool as a gem's rake file asks about it: the command and flags, and no system headers (search_header_path
  # finds nothing, so an mrbgem.rake falls back to its bundled build, as mruby's rake build does on a host
  # without the library).
  class ToolQuery
    attr_reader :command, :flags

    def initialize(command, flags)
      @command = command
      @flags = flags
    end

    def search_header_path(_name)
      nil
    end
  end

  # `build` in an mrbgem.rake (and `spec.build`): the build-wide settings a gem can add to.
  class BuildRef
    # libmruby_core_objs: object paths (under BUILD_DIR_PLACEHOLDER) that a gem adds to the core archive.
    attr_reader :defines, :bins, :libmruby_core_objs, :project

    def initialize(project)
      @project = project
      @defines = []
      @bins = []
      @libmruby_core_objs = []
    end

    # mruby-io checks that a HAL gem is in the build. The target's closure is not known yet, so the config's
    # names stand in for it (a HAL the closure lacks would fail the link).
    def gems
      project.config_names.map { |n| Struct.new(:name).new(n) }
    end

    def cc
      ToolQuery.new(project.conf.cc.command || 'cc', C_FLAGS)
    end

    def build_dir
      BUILD_DIR_PLACEHOLDER
    end

    # Named only as the link input of the mrbc tool, whose archive the generator places itself.
    def libmruby_core_static
      "#{BUILD_DIR_PLACEHOLDER}/lib/libmruby_core.a"
    end

    def name
      'host'
    end

    def method_missing(name, *_args, &_block)
      raise "mrbgem.rake: build.#{name} is not supported by mruby-ninja"
    end

    def respond_to_missing?(*)
      false
    end
  end

  # One gem, as its mrbgem.rake describes it.
  class GemSpec
    IGNORED_SETTERS = %i[license= summary= author= authors= add_test_dependency].freeze

    attr_reader :dir, :dependencies, :build, :cc, :linker, :version, :core_sources
    attr_accessor :name

    def initialize(dir, project)
      @dir = dir
      @project = project
      @name = nil
      @dependencies = []
      @build = BuildRef.new(project)
      @cc = Struct.new(:defines, :include_paths).new([], [])
      @linker = Struct.new(:libraries).new([])
      @version = '0.0.0'
      @core_sources = false
      @bins = []
    end

    def bins
      (@bins + @build.bins).uniq
    end

    def bins=(list)
      @bins = list
    end

    def version=(v)
      @version = v
    end

    def add_dependency(name, opts = {})
      raise "mrbgem.rake of #{@name}: dependency #{name} needs :core or :mgem" unless opts[:core] || opts[:mgem]

      @dependencies << name
    end

    # The block is not run: the compiler gem's core/*.c is the only build_settings this script models.
    def build_settings(&_block)
      @core_sources = true
    end

    def for_windows?
      false
    end

    def build_dir
      BUILD_DIR_PLACEHOLDER
    end

    def objfile(path)
      path
    end

    def exefile(path)
      path
    end

    def libfile(path)
      "#{path}.a"
    end

    def _pp(*_args); end

    def method_missing(name, *_args, &_block)
      return nil if IGNORED_SETTERS.include?(name)

      raise "mrbgem.rake of #{@name || @dir}: #{name} is not supported by mruby-ninja"
    end

    def respond_to_missing?(*)
      false
    end
  end

  # Loads mrbgem.rake files and computes the closure. The DSL the files use is defined below the class.
  class Project
    attr_reader :src, :config_names
    attr_accessor :conf

    def initialize(src)
      @src = File.expand_path(src)
      @specs = {}
      @loading = nil
      @config_names = []
      $mruby_ninja_project = self
    end

    # Loads the config's gems (core names or paths) and returns their names, in config order.
    def register_config(entries)
      @config_names = entries.map do |kind, value|
        kind == :core ? value : spec_for_dir(value).name
      end
    end

    # The gems in the order mruby's build visits them (lib/mruby/gem.rb: tsort_dependencies).
    def closure(roots)
      ary = roots.dup
      left = ary.dup
      until left.empty?
        v = left.pop
        spec_named(v).dependencies.each do |dep|
          left.push dep
          ary.push dep
        end
      end
      ary.uniq!
      Table.new(self, ary).tsort
    end

    def spec_named(name)
      @specs[name] ||= spec_for_dir(File.join(@src, 'mrbgems', name))
    end

    def spec_for_dir(dir)
      rake = File.join(dir, 'mrbgem.rake')
      raise "#{dir}: no mrbgem.rake" unless File.exist?(rake)

      spec = GemSpec.new(dir, self)
      @loading = spec
      begin
        load rake
      ensure
        @loading = nil
      end
      raise "#{rake} declares no gem" unless spec.name

      @specs[spec.name] ||= spec
    end

    # MRuby::Gem::Specification.new(name) { |spec| ... } while a gem loads.
    def declare(name, &block)
      raise "#{name}: Specification.new outside of a mrbgem.rake" unless @loading

      @loading.name = name
      @loading.instance_exec(@loading, &block) if block
    end

    # The dependency-closure table, for TSort: nodes are the roots, children are the dependencies.
    class Table
      include TSort

      def initialize(project, roots)
        @project = project
        @roots = roots
      end

      def tsort_each_node(&block)
        @roots.each(&block)
      end

      def tsort_each_child(name, &block)
        @project.spec_named(name).dependencies.each(&block)
      end
    end
  end
end

# Rake's String#pathmap, for the patterns mrbgem.rake files use: %n (basename without extension), %X (the path
# without extension), %f (basename), %x (extension) and %d (directory).
class String
  def relative_path_from(base)
    Pathname.new(self).relative_path_from(Pathname.new(base)).to_s
  end

  def pathmap(pattern)
    pattern.gsub(/%[nXfxd]/) do |token|
      case token
      when '%n' then File.basename(self, File.extname(self))
      when '%X' then self.delete_suffix(File.extname(self))
      when '%f' then File.basename(self)
      when '%x' then File.extname(self)
      when '%d' then File.dirname(self)
      end
    end
  end
end

# The DSL a config and mrbgem.rake files see at top level. Rake's DSL does nothing here: the generator writes the
# products those tasks would build.
def file(*_args, **_opts, &_block) = nil
def task(*_args, **_opts, &_block) = nil
def rule(*_args, **_opts, &_block) = nil
def directory(*_args, **_opts, &_block) = nil
def desc(*_args) = nil
def sh(*_args) = nil

module MRuby
  class Build
    def self.new(*_args)
      conf = MrubyNinja::Conf.new
      yield conf
      $mruby_ninja_conf = conf
    end
  end

  # mrbgem.rake checks `build.kind_of?(MRuby::CrossBuild)`; this build never is one.
  class CrossBuild; end

  module Gem
    class Specification
      def self.new(name, &block)
        $mruby_ninja_project.declare(name, &block)
      end
    end
  end
end

module Rake
  class Task
    def self.task_defined?(_name)
      false
    end
  end
end

module MrubyNinja
  # Writes build.ninja: the mrbc sub-build first (it is run by the host build's mrblib and gem steps), then the host build.
  class Emitter
    include Shellwords

    Target = Struct.new(:name, :build_dir, :gems, :libmruby)

    def initialize(project, conf, mruby_src, out)
      @project = project
      @conf = conf
      @mruby_src = mruby_src
      @out = out
      @statements = []
      @default_bins = []
      @default_libs = []
    end

    def emit
      sub = Target.new('host/mrbc', File.join(@out, 'host', 'mrbc'),
                       @project.closure(%w[mruby-bin-mrbc]), false)
      host_gems = @project.closure(@project.config_names).reject { |n| SUB_BUILD_GEMS.include?(n) }
      host = Target.new('host', File.join(@out, 'host'), host_gems, true)

      @mrbc_exe = File.join(sub.build_dir, 'bin', 'mrbc')
      header
      emit_target(sub)
      emit_target(host)
      @statements << "build all: phony #{(@default_bins + @default_libs).map { |b| ninja_path(b) }.join(' ')}"
      @statements << 'default all'
      @statements.join("\n") + "\n"
    end

    private

    def header
      @statements << <<~NINJA.chomp
        ninja_required_version = 1.7
        cc = #{@conf.cc.command || 'cc'}
        ar = #{@conf.archiver.command || 'ar'}
        ldflags = #{ninja_value(ENV['LDFLAGS'])}
        mrbc = #{ninja_value(@mrbc_exe)}
        ruby = #{ninja_value(RbConfig.ruby)}
        gen = #{ninja_value(File.expand_path(__FILE__))}
        mruby_src = #{ninja_value(@mruby_src)}

        rule cc
          command = $cc -MMD -MF $out.d $flags -c $in -o $out
          depfile = $out.d
          deps = gcc
          description = CC $out

        rule cpp
          command = $cc -E -P $flags -o $out $in
          description = CPP $out

        # restat: a rebuilt mrbc that emits the same C leaves the file (and the objects that include it) alone.
        rule mrbc
          command = $mrbc -B$fn -o- -S -s $in > $out.tmp && (cmp -s $out.tmp $out || mv $out.tmp $out); rm -f $out.tmp
          restat = 1
          description = MRBC $out

        rule presym
          command = $ruby $gen presym $mruby_src $builddir $in
          restat = 1
          description = PRESYM $builddir

        rule ar
          command = rm -f $out && $ar rs $out $in
          description = AR $out

        rule link
          command = $cc $ldflags -o $out $in $libs
          description = LINK $out

        rule onigmo
          command = $ruby $gen onigmo $in $builddir $onigenv
          description = ONIGMO $builddir
      NINJA
    end

    def emit_target(target)
      bd = target.build_dir
      gems = target.gems.map { |n| @project.spec_named(n) }
      if !target.libmruby && gems.any? { |g| generates_functions?(g) }
        raise "#{target.name}: a gem with generated init functions needs libmruby (not supported here)"
      end

      defines = (@conf.cc.defines + gems.flat_map { |g| g.build.defines }).uniq
      base_includes = [File.join(@mruby_src, 'include'), File.join(bd, 'include')]
      base_flags = cflags(defines, base_includes)

      # Compile units, each with its object, flags and the generated files it includes.
      units = []
      core_objs = []
      Dir.glob(File.join(@mruby_src, 'src', '*.c')).sort.each do |src|
        obj = File.join(bd, 'src', "#{File.basename(src, '.c')}.o")
        units << { src: src, obj: obj, flags: base_flags, implicit: [] }
        core_objs << obj
      end

      gem_objs = []
      @extra_inputs = []
      @extra_libs = []
      gems.each do |g|
        gbd = File.join(bd, 'mrbgems', g.name)
        gdefs = ["MRBGEM_#{g.name.tr('-', '_').upcase}_VERSION=#{g.version}"] + subst_build_dir(g.cc.defines, gbd)
        gincs = gem_include_dirs(g) + subst_build_dir(g.cc.include_paths, gbd)
        gflags = cflags(defines + gdefs, base_includes + gincs)
        implicit = []
        if g.singleton_methods.include?(:bundle_onigmo)
          lib = emit_onigmo(g, gbd)
          implicit << lib
          @extra_inputs << lib
        end
        @extra_libs += g.linker.libraries.map { |l| "-l#{l}" }
        sources = Dir.glob(File.join(g.dir, 'src', '*.c')).sort
        sources = Dir.glob(File.join(g.dir, 'core', '*.c')).sort + sources if g.core_sources
        sources.each do |src|
          obj = File.join(gbd, relative(src, g.dir).sub(/\.c\z/, '.o'))
          units << { src: src, obj: obj, flags: gflags, implicit: implicit }
          (g.core_sources && src.start_with?(File.join(g.dir, 'core')) ? core_objs : gem_objs) << obj
        end
        # A gem's build_settings may add objects to the core archive (mruby-bigint's core/**/*.c).
        g.build.libmruby_core_objs.flatten.each do |placeholder_obj|
          rel = placeholder_obj.delete_prefix("#{BUILD_DIR_PLACEHOLDER}/")
          src = File.join(g.dir, "#{rel}.c")
          obj = File.join(gbd, "#{rel}.o")
          units << { src: src, obj: obj, flags: gflags, implicit: implicit }
          core_objs << obj
        end
        Dir.glob(File.join(g.dir, 'tools', '*')).sort.each do |tool|
          next unless File.directory?(tool)

          Dir.glob(File.join(tool, '*.c')).sort.each do |src|
            obj = File.join(gbd, relative(src, g.dir).sub(/\.c\z/, '.o'))
            units << { src: src, obj: obj, flags: gflags, implicit: implicit }
          end
        end
        emit_gem_init(g, gbd, gflags, units, gem_objs) if generates_functions?(g)
      end

      mrblib_objs = []
      if target.libmruby
        emit_mrblib(bd, base_flags, units, mrblib_objs)
        emit_top_gem_init(gems, bd, base_flags, units, gem_objs)
      end

      # The presym pass: every object of this target is preprocessed for symbols, then the headers are written.
      pis = units.map { |u| u[:obj].sub(/\.o\z/, PRESYM_EXT) }
      headers = [File.join(bd, 'include', 'mruby', 'presym', 'id.h'), File.join(bd, 'include', 'mruby', 'presym', 'table.h')]
      units.each do |u|
        pi = u[:obj].sub(/\.o\z/, PRESYM_EXT)
        @statements << "build #{ninja_path(pi)}: cpp #{ninja_path(u[:src])}#{implicit_suffix(u[:implicit])}\n" \
                       "  flags = #{ninja_value(u[:flags] + ' -DMRB_PRESYM_SCANNING')}"
      end
      @statements << "build #{ninja_path(File.join(bd, 'presym'))} | #{headers.map { |h| ninja_path(h) }.join(' ')}: " \
                     "presym #{pis.map { |p| ninja_path(p) }.join(' ')}\n  builddir = #{ninja_value(bd)}"

      units.each do |u|
        @statements << "build #{ninja_path(u[:obj])}: cc #{ninja_path(u[:src])}#{implicit_suffix(u[:implicit])} || " \
                       "#{headers.map { |h| ninja_path(h) }.join(' ')}\n  flags = #{ninja_value(u[:flags])}"
      end

      archive = File.join(bd, 'lib', target.libmruby ? 'libmruby.a' : 'libmruby_core.a')
      if target.libmruby
        archive_objs = core_objs + gem_objs + mrblib_objs
        @statements << "build #{ninja_path(File.join(bd, 'lib', 'libmruby_core.a'))}: ar " \
                       "#{core_objs.map { |o| ninja_path(o) }.join(' ')}"
      else
        archive_objs = core_objs
      end
      @statements << "build #{ninja_path(archive)}: ar #{archive_objs.map { |o| ninja_path(o) }.join(' ')}"
      @default_libs << archive
      @default_libs << File.join(bd, 'lib', 'libmruby_core.a') if target.libmruby

      emit_bins(target, gems, archive)
    end

    # Each bin is one gem's tools/<bin>/*.c, linked with the archive (libmruby, or the core for the mrbc tool).
    # The libraries of the target's gems (mruby's linker.libraries: m, pthread) come after the archives, as they do
    # in mruby's link command.
    def emit_bins(target, gems, archive)
      gems.each do |g|
        g.bins.each do |bin|
          objs = Dir.glob(File.join(g.dir, 'tools', bin, '*.c')).sort.map do |src|
            File.join(target.build_dir, 'mrbgems', g.name, relative(src, g.dir).sub(/\.c\z/, '.o'))
          end
          exe = File.join(target.build_dir, 'bin', bin)
          inputs = objs.map { |o| ninja_path(o) }
          if CORE_LINKED_BINS.include?(bin)
            inputs << ninja_path(File.join(target.build_dir, 'lib', 'libmruby_core.a'))
            libs = ['-lm']
          else
            inputs << ninja_path(archive)
            inputs += @extra_inputs.map { |i| ninja_path(i) }
            libs = ['-lm'] + @extra_libs
          end
          @statements << "build #{ninja_path(exe)}: link #{inputs.join(' ')}\n  libs = #{ninja_value(libs.join(' '))}"
          @default_bins << exe
        end
      end
    end

    def subst_build_dir(list, gbd)
      list.map { |s| s.gsub(BUILD_DIR_PLACEHOLDER, gbd) }
    end

    # mruby-onig-regexp bundles Onigmo when no system header is found (its mrbgem.rake, bundle_onigmo): the tarball is
    # unpacked, configured and built with make, in the gem's build directory, with the build's CC, LD and AR.
    # Returns the library the gem's sources and the bins need.
    def emit_onigmo(g, gbd)
      tarball = Dir.glob(File.join(g.dir, 'onigmo-*.tar.gz')).sort.first or
        raise "#{g.name}: no bundled Onigmo tarball in #{g.dir}"
      match = ONIGMO_VERSION_RE.match(File.basename(tarball))
      raise "#{g.name}: cannot read the Onigmo version from #{File.basename(tarball)}" unless match

      version = match[1]
      dir = File.join(gbd, "onigmo-#{version}")
      lib = File.join(dir, '.libs', 'libonigmo.a')
      cc = @conf.cc.command || 'cc'
      env = ["CC=#{[cc, *C_FLAGS].join(' ')}", "LD=#{@conf.linker.command || cc}", "AR=#{@conf.archiver.command || 'ar'}"]
      @statements << "build #{ninja_path(lib)}: onigmo #{ninja_path(tarball)}\n" \
                     "  builddir = #{ninja_value(dir)}\n  onigenv = #{ninja_value(Shellwords.join(env))}"
      lib
    end

    def emit_mrblib(bd, base_flags, units, mrblib_objs)
      rbs = Dir.glob(File.join(@mruby_src, 'mrblib', '*.rb')).sort
      proc_c = File.join(bd, 'mrblib', 'mrblib_proc.c')
      wrapper = File.join(bd, 'mrblib', 'mrblib.c')
      @statements << "build #{ninja_path(proc_c)}: mrbc #{rbs.map { |r| ninja_path(r) }.join(' ')} | #{ninja_path(@mrbc_exe)}\n" \
                     "  fn = mrblib_proc"
      write_if_changed(wrapper, mrblib_wrapper)
      obj = File.join(bd, 'mrblib', 'mrblib.o')
      units << { src: wrapper, obj: obj, flags: base_flags, implicit: [proc_c] }
      mrblib_objs << obj
    end

    def emit_gem_init(g, gbd, gflags, units, gem_objs)
      rbs = Dir.glob(File.join(g.dir, 'mrblib', '**', '*.rb')).sort
      gem_init_c = File.join(gbd, 'gem_init.c')
      implicit = []
      unless rbs.empty?
        mrblib_c = File.join(gbd, 'gem_mrblib.c')
        @statements << "build #{ninja_path(mrblib_c)}: mrbc #{rbs.map { |r| ninja_path(r) }.join(' ')} | #{ninja_path(@mrbc_exe)}\n" \
                       "  fn = gem_mrblib_#{funcname(g)}_proc"
        implicit << mrblib_c
      end
      write_if_changed(gem_init_c, gem_init_text(g, !rbs.empty?))
      obj = File.join(gbd, 'gem_init.o')
      units << { src: gem_init_c, obj: obj, flags: gflags, implicit: implicit }
      gem_objs << obj
    end

    def emit_top_gem_init(gems, bd, base_flags, units, gem_objs)
      path = File.join(bd, 'mrbgems', 'gem_init.c')
      write_if_changed(path, top_gem_init_text(gems.select { |g| generates_functions?(g) }))
      obj = File.join(bd, 'mrbgems', 'gem_init.o')
      units << { src: path, obj: obj, flags: base_flags, implicit: [] }
      gem_objs << obj
    end

    # lib/mruby/gem.rb: generate_functions is true when the gem has Ruby sources or C sources.
    def generates_functions?(g)
      !(Dir.glob(File.join(g.dir, 'mrblib', '**', '*.rb')).empty? && Dir.glob(File.join(g.dir, 'src', '*.c')).empty?)
    end

    # gem.rb: a gem's own include dir and those of its dependencies, recursively.
    def gem_include_dirs(g, seen = {})
      dirs = []
      inc = File.join(g.dir, 'include')
      dirs << inc if File.directory?(inc)
      g.dependencies.each do |dep|
        next if seen[dep]

        seen[dep] = true
        dirs += gem_include_dirs(@project.spec_named(dep), seen)
      end
      dirs.uniq
    end

    def cflags(defines, includes)
      (C_FLAGS + defines.map { |d| "-D#{d}" } + includes.map { |i| "-I#{i}" }).map { |f| Shellwords.escape(f) }.join(' ')
    end

    def implicit_suffix(implicit)
      implicit.empty? ? '' : " | #{implicit.map { |p| ninja_path(p) }.join(' ')}"
    end

    def funcname(g)
      g.name.tr('-', '_')
    end

    def relative(path, base)
      path.delete_prefix("#{base}/")
    end

    def gem_init_text(g, has_rb)
      f = funcname(g)
      has_c = !Dir.glob(File.join(g.dir, 'src', '*.c')).empty?
      out = +"/*\n * This file is loading the irep\n * Ruby GEM code.\n *\n * This file was generated by mruby/scripts/mruby-ninja.rb.\n" \
             " *\n * IMPORTANT:\n *   This file was generated!\n *   All manual changes will get lost.\n */\n"
      if has_rb
        out << "#include <stdlib.h>\n#include \"gem_mrblib.c\"\n"
      else
        out << "#include <mruby.h>\n"
      end
      out << "\nvoid mrb_#{f}_gem_init(mrb_state *mrb);\nvoid mrb_#{f}_gem_final(mrb_state *mrb);\n"
      out << "\nvoid GENERATED_TMP_mrb_#{f}_gem_init(mrb_state *mrb) {\n"
      out << "  gem_mrblib_#{f}_proc_init_syms(mrb);\n" if has_rb
      out << "  mrb_#{f}_gem_init(mrb);\n" if has_c
      out << "  mrb_load_proc(mrb, gem_mrblib_#{f}_proc);\n" if has_rb
      out << "}\n\nvoid GENERATED_TMP_mrb_#{f}_gem_final(mrb_state *mrb) {\n"
      out << "  mrb_#{f}_gem_final(mrb);\n" if has_c
      out << "}\n"
      out
    end

    # mrbgems/gem_init.c: calls each gem's init in the closure's order, and the finalizers at exit.
    def top_gem_init_text(gems)
      out = +"/*\n * This file contains a list of all\n * initializing methods which are\n * necessary to bootstrap all gems.\n *\n" \
             " * This file was generated by mruby/scripts/mruby-ninja.rb.\n *\n * IMPORTANT:\n *   This file was generated!\n" \
             " *   All manual changes will get lost.\n */\n\n#include <mruby.h>\n#include <mruby/error.h>\n#include <mruby/proc.h>\n\n"
      unless gems.empty?
        gems.each do |g|
          out << "void GENERATED_TMP_mrb_#{funcname(g)}_gem_init(mrb_state*);\n" \
                 "void GENERATED_TMP_mrb_#{funcname(g)}_gem_final(mrb_state*);\n"
        end
        out << "\nstatic const struct {\n  void (*init)(mrb_state*);\n  void (*final)(mrb_state*);\n} gem_funcs[] = {\n"
        gems.each { |g| out << "  { GENERATED_TMP_mrb_#{funcname(g)}_gem_init, GENERATED_TMP_mrb_#{funcname(g)}_gem_final },\n" }
        out << "};\n\n#define NUM_GEMS ((int)(sizeof(gem_funcs) / sizeof(gem_funcs[0])))\n\n" \
               "struct final_mrbgems {\n  int i;\n  int ai;\n};\n\nstatic mrb_value\nfinal_mrbgems_body(mrb_state *mrb, void *ud) {\n" \
               "  struct final_mrbgems *p = (struct final_mrbgems*)ud;\n  for (; p->i >= 0; p->i--) {\n" \
               "    gem_funcs[p->i].final(mrb);\n    mrb_gc_arena_restore(mrb, p->ai);\n  }\n  return mrb_nil_value();\n}\n\n" \
               "static void\nmrb_final_mrbgems(mrb_state *mrb) {\n  struct final_mrbgems a = { NUM_GEMS - 1, mrb_gc_arena_save(mrb) };\n" \
               "  for (; a.i >= 0; a.i--) {\n    mrb_protect_error(mrb, final_mrbgems_body, &a, NULL);\n" \
               "    mrb_gc_arena_restore(mrb, a.ai);\n  }\n}\n\n"
        out << "void\nmrb_init_mrbgems(mrb_state *mrb) {\n  int ai = mrb_gc_arena_save(mrb);\n" \
               "  for (int i = 0; i < NUM_GEMS; i++) {\n    gem_funcs[i].init(mrb);\n    mrb_gc_arena_restore(mrb, ai);\n" \
               "    mrb_vm_ci_env_clear(mrb, mrb->c->cibase);\n    if (mrb->exc) {\n      mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));\n    }\n  }\n" \
               "  mrb_state_atexit(mrb, mrb_final_mrbgems);\n}\n"
      else
        out << "void\nmrb_init_mrbgems(mrb_state *mrb) {\n}\n"
      end
      out
    end

    def mrblib_wrapper
      "/*\n * This file is loading the mrblib\n *\n * IMPORTANT:\n *   This file was generated!\n *   All manual changes will get lost.\n */\n" \
        "#include <mruby.h>\n#include <mruby/proc.h>\n#include \"mrblib_proc.c\"\n" \
        "void\nmrb_init_mrblib(mrb_state *mrb)\n{\n  mrblib_proc_init_syms(mrb);\n  mrb_load_proc(mrb, mrblib_proc);\n}\n"
    end

    def write_if_changed(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      return if File.exist?(path) && File.read(path) == text

      File.write(path, text)
    end

    # Ninja paths: a space, colon or dollar in a path is escaped with $.
    def ninja_path(path)
      path.gsub(/[ :$]/) { |c| "$#{c}" }
    end

    # Ninja values: only $ is special in a variable's value.
    def ninja_value(text)
      text.to_s.gsub('$', '$$')
    end
  end

  # The presym pass (run by ninja): mruby's own scanner and header writers, given the preprocessed sources.
  def self.presym(mruby_src, build_dir, ppps)
    require File.join(File.expand_path(mruby_src), 'lib', 'mruby', 'presym')
    MRuby::Presym.class_eval do
      def _pp(*_args); end
    end
    String.class_eval do
      def relative_path
        self
      end
    end
    presym = MRuby::Presym.new(Struct.new(:build_dir).new(build_dir))
    presyms = presym.scan(ppps)
    current = presym.read_list if File.exist?(presym.list_path)
    return if presyms == current

    FileUtils.mkdir_p(presym.header_dir)
    presym.write_id_header(presyms)
    presym.write_table_header(presyms)
    presym.write_list(presyms)
  end

  # The bundled Onigmo build (run by ninja): unpack, configure and make, as mruby-onig-regexp's bundle_onigmo does.
  def self.onigmo(tarball, builddir, *env_pairs)
    require 'etc'
    env = env_pairs.to_h { |pair| pair.split('=', 2) }
    run = lambda do |cmd|
      system(env, cmd) or raise "#{cmd} failed in #{Dir.pwd}"
    end
    FileUtils.mkdir_p(File.dirname(builddir))
    Dir.chdir(File.dirname(builddir)) { run.("gzip -dc #{Shellwords.escape(File.expand_path(tarball))} | tar xf -") }
    Dir.chdir(builddir) do
      run.('./autogen.sh') if File.exist?('autogen.sh')
      run.('./configure --disable-shared --enable-static')
      run.("make -j#{Etc.nprocessors} libonigmo.la onigmo.pc")
    end
  end

  def self.generate(mruby_src, config, out)
    ENV['NFCXX_ROOT'] ||= File.expand_path('..', __dir__)
    mruby_src = File.expand_path(mruby_src)
    out = File.expand_path(out)
    Object.const_set(:MRUBY_ROOT, mruby_src) unless Object.const_defined?(:MRUBY_ROOT) # the Rakefile sets it too
    project = Project.new(mruby_src)
    load File.expand_path(config)
    conf = $mruby_ninja_conf or raise 'the config did not declare MRuby::Build'

    project.conf = conf
    project.register_config(conf.gem_entries)
    FileUtils.mkdir_p(out)
    File.write(File.join(out, 'build.ninja'), Emitter.new(project, conf, mruby_src, out).emit)
  end
end

if __FILE__ == $PROGRAM_NAME
  cmd, *args = ARGV
  case cmd
  when 'generate'
    abort 'usage: mruby-ninja.rb generate MRUBY_SRC CONFIG OUT' unless args.size == 3
    MrubyNinja.generate(*args)
  when 'presym'
    abort 'usage: mruby-ninja.rb presym MRUBY_SRC BUILD_DIR PPP...' if args.size < 2
    MrubyNinja.presym(args[0], args[1], args[2..])
  when 'onigmo'
    abort 'usage: mruby-ninja.rb onigmo TARBALL BUILDDIR [VAR=VALUE...]' if args.size < 2
    MrubyNinja.onigmo(args[0], args[1], *args[2..])
  else
    abort 'usage: mruby-ninja.rb generate MRUBY_SRC CONFIG OUT | presym MRUBY_SRC BUILD_DIR PPP... | onigmo ...'
  end
end
