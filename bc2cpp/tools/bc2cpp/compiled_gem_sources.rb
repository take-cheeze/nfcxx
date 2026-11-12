# frozen_string_literal: true

# The mrbgem.rake and src/register.cxx of each bc2cpp-generated gem (compiled_gems.yml), written from the table, so no
# copy of them is tracked. Gems keep their rake logic at the gem root: the build loads it from there, and bc2cpp's
# closed-world readers read it from there too (bc2cpp_gem_rake_text).
#
#   ruby compiled_gem_sources.rb <dir> <world>   writes <dir>/<gem>/mrbgem.rake and <dir>/<gem>/src/register.cxx; <world> is the
#                                                repository the base gems (owners_from) live in

require 'fileutils'
require_relative 'compiled_gems_config'

module CompiledGemSources
  FIBER_PLACEHOLDER = 'mruby-fiber-placeholder'
  CORE = Bc2cppCompiledGemsConfig::CORE

  # Gem rake of a compiled gem that depends on one base gem (owners_from). @NAME@, @BASE@, @SYM@ are filled in.
  GEM_RAKE = <<~'RAKE'
    require 'shellwords'
    require_relative '../tools/bc2cpp_tree'
    require File.join(BC2CPP_TREE, 'tools/bc2cpp/compiled_gems')

    MRuby::Gem::Specification.new('@NAME@') do |spec|
      spec.license = 'MIT'
      spec.author = 'take-cheeze'
      spec.summary = 'Opt-in AOT-compiled C++ replacements for @BASE@ bytecode methods'

      add_dependency '@BASE@'

      bc2cpp_tool_srcs = Dir["#{BC2CPP_TREE_ROOT}/tools/bc2cpp/*.rb"]
      compiled_gems_rb = "#{BC2CPP_TREE_ROOT}/tools/bc2cpp/compiled_gems.rb"
      compiled_gems_yml = "#{BC2CPP_TREE_ROOT}/tools/bc2cpp/compiled_gems.yml"
      closed_world_prereqs = bc2cpp_closed_world_prerequisites("#{dir}/..")
      native_srcs = bc2cpp_rgss_native_srcs("#{dir}/..", build.name) + core_native_srcs("#{dir}/../3rd/mruby") +
                    external_gem_native_srcs("#{dir}/..")
      foreign_ruby_srcs = foreign_mrblib_srcs("#{dir}/..")
      other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == '@NAME@' }
      other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }
      generated = "#{build_dir}/@SYM@_gen.cpp"
      mrbc_edge = ENV['BC2CPP_USE_BUILD_MRBC'] == '1' ? [spec.build.mrbcfile] : []
      file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, *mrbc_edge, *closed_world_prereqs, *native_srcs,
                         *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/..")] do |t|
        Bc2cppCompiledGemGeneration.generate(spec, "#{dir}/..")
      end
      file "#{dir}/src/register.cxx" => [generated, *other_generated]
      bc2cpp_compiled_gem_shards(spec, generated, other_generated)
      cxx.include_paths << build_dir
      cxx.defines << 'BC2CPP_FAIL_FAST_TYPE' if BC2CPP_FAIL_FAST_TYPE
      cxx.include_paths << "#{dir}/../include"
    end
  RAKE

  # mruby's own Ruby: the core gems it depends on are listed in build_config's loops, not as add_dependency lines.
  CORE_RAKE = <<~'RAKE'
    require 'shellwords'
    require_relative '../tools/bc2cpp_tree'
    require File.join(BC2CPP_TREE, 'tools/bc2cpp/compiled_gems')

    MRuby::Gem::Specification.new('mruby-core-compiled') do |spec|
      spec.license = 'MIT'
      spec.author = 'take-cheeze'
      spec.summary = 'Opt-in AOT-compiled C++ replacements for listed mruby core mrblib methods'

      %w[mruby-lcf mruby-rgss mruby-rpg2k].each { |gem_name| add_dependency gem_name }
      (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
        next if %w[mruby-dir mruby-onig-regexp mruby-struct].include?(gem_name) && spec.build.gems.none? { |g| g.name == gem_name }

        add_dependency gem_name
      end

      bc2cpp_tool_srcs = Dir["#{BC2CPP_TREE_ROOT}/tools/bc2cpp/*.rb"]
      compiled_gems_rb = "#{BC2CPP_TREE_ROOT}/tools/bc2cpp/compiled_gems.rb"
      compiled_gems_yml = "#{BC2CPP_TREE_ROOT}/tools/bc2cpp/compiled_gems.yml"
      closed_world_prereqs = bc2cpp_closed_world_prerequisites("#{dir}/..")
      native_srcs = bc2cpp_rgss_native_srcs("#{dir}/..", build.name) + core_native_srcs("#{dir}/../3rd/mruby") +
                    external_gem_native_srcs("#{dir}/..")
      foreign_ruby_srcs = foreign_mrblib_srcs("#{dir}/..")
      other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == 'mruby-core-compiled' }
      other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }
      generated = "#{build_dir}/core_compiled_gen.cpp"
      mrbc_edge = ENV['BC2CPP_USE_BUILD_MRBC'] == '1' ? [spec.build.mrbcfile] : []
      file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, *mrbc_edge, *closed_world_prereqs, *native_srcs,
                         *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/..")] do |t|
        Bc2cppCompiledGemGeneration.generate(spec, "#{dir}/..")
      end
      file "#{dir}/src/register.cxx" => [generated, *other_generated]
      bc2cpp_compiled_gem_shards(spec, generated, other_generated)
      cxx.include_paths << build_dir
      cxx.defines << 'BC2CPP_FAIL_FAST_TYPE' if BC2CPP_FAIL_FAST_TYPE
      cxx.include_paths << "#{dir}/../include"
    end
  RAKE

  FIBER_RAKE = <<~'RAKE'
    # Source-less stand-in for mruby-fiber in the closed build: the program supplies Fiber (bc2cpp_fiber_define).
    MRuby::Gem::Specification.new('mruby-fiber') do |spec|
      spec.license = 'MIT'
      spec.authors = 'bc2cpp'
      spec.summary = 'placeholder: no sources, no mrb_fiber_* symbols'
    end
  RAKE

  module_function

  # The table entries that are generated gems (the fiber stand-in is not in the table).
  def entries(gems_root)
    Bc2cppCompiledGemsConfig.load(gems_root: gems_root)
  end

  def generated?(name, gems_root)
    name == FIBER_PLACEHOLDER || entries(gems_root).any? { |e| e.name == name }
  end

  def rake_text(name, gems_root)
    return FIBER_RAKE if name == FIBER_PLACEHOLDER

    entry = entries(gems_root).find { |e| e.name == name } or raise Bc2cppCompiledGemsConfig::Error, "no compiled gem #{name}"
    return CORE_RAKE if entry.owners_from == CORE

    GEM_RAKE.gsub('@NAME@', name).gsub('@BASE@', entry.owners_from).gsub('@SYM@', entry.out_symbol)
  end

  def register_text(name, gems_root)
    return nil if name == FIBER_PLACEHOLDER

    entry = entries(gems_root).find { |e| e.name == name } or raise Bc2cppCompiledGemsConfig::Error, "no compiled gem #{name}"
    ident = name.tr('-', '_')
    <<~CXX
      // The compiled bodies of this gem's Ruby methods (generated by tools/bc2cpp/compiled_gem_sources.rb).
      #include <mruby.h>
      #include <mruby/class.h>

      #include "#{entry.out_symbol}_gen.cpp"

      extern "C" void mrb_#{ident}_gem_init(mrb_state* M) {
        bc2cpp_gem_init(M);
      }

      extern "C" void mrb_#{ident}_gem_final(mrb_state*) {
        bc2cpp_gem_final();
      }
    CXX
  end

  # Writes every gem's files under dest; a file is rewritten only when its content differs, so a rebuild keeps mtimes.
  def write!(dest, gems_root)
    names = entries(gems_root).map(&:name) + [FIBER_PLACEHOLDER]
    names.each do |name|
      write_if_changed(File.join(dest, name, 'mrbgem.rake'), rake_text(name, gems_root))
      register = register_text(name, gems_root)
      write_if_changed(File.join(dest, name, 'src', 'register.cxx'), register) if register
    end
    names.map { |name| File.join(dest, name) }
  end

  def write_if_changed(path, text)
    return if File.file?(path) && File.read(path) == text

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
end

if $PROGRAM_NAME == __FILE__
  CompiledGemSources.write!(ARGV.fetch(0), ARGV.fetch(1))
end
