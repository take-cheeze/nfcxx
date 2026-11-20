# frozen_string_literal: true

require_relative 'world_root'

# LISTS_WORLD: the build whose binary the closed-list proof (static_dispatch_registrations.rb) reads, named by
# BC2CPP_LISTS_WORLD (default `closed`). A lists file is proven for that one build's world, and records it (`world`):
# only a build of the same name takes its closed-only parts (StaticDispatchLists::Lists#closed_for?).
#
# A world differs from the closed one only in what its binary links: its gem list (build_config.rb's rpg_maker_gems for
# that conf.name, and their add_dependency closure) and its native host sources. Its Ruby must be the closed world's
# (closed_world_mrblib_srcs), less files only: a world whose build compiles other engine Ruby is no world here.
module ListsWorld
  ENV_NAME = 'BC2CPP_LISTS_WORLD'
  # name => the native sources outside the gems its binary links: the closed library runs in trace_host.cxx; the wio
  # firmware is platformio.ini's env:wio (build_src_filter: wio_rgss_boot_main.cxx) plus the HAL gem its stanza adds.
  HOSTS = {
    'closed' => ->(_root) { [File.expand_path('scripts/bc2cpp/trace_host.cxx', BC2CPP_TREE_ROOT)] },
    'wio' => lambda do |root|
      ["#{root}/app/wio/src/wio_rgss_boot_main.cxx"] +
        Dir["#{root}/app/wio/{hal-wio-io,mruby-math-wio}/{src,include}/**/*.{c,cc,cpp,cxx,h,hh,hpp,hxx,inc}"].sort
    end
  }.freeze
  # name => gem directories its rake adds outside rpg_maker_gems (the wio stanza's `conf.gem .../hal-wio-io`).
  EXTRA_GEMS = { 'closed' => [], 'wio' => %w[app/wio/hal-wio-io] }.freeze

  module_function

  def name(env = ENV)
    world = env[ENV_NAME].to_s
    world = 'closed' if world.empty?
    raise "#{ENV_NAME}=#{world} is not one of #{HOSTS.keys.join('/')}" unless HOSTS.key?(world)

    world
  end

  def closed?(env = ENV)
    name(env) == 'closed'
  end

  def host_natives(root, world = name)
    HOSTS.fetch(world).call(File.expand_path(root)).map { |p| File.expand_path(p) }
  end

  # Directory prefixes under app/ the world links (app/ itself is unlinked otherwise).
  def linked_app_dirs(root, world = name)
    root = File.expand_path(root)
    (EXTRA_GEMS.fetch(world) + (world == 'wio' ? %w[app/wio/mruby-math-wio] : [])).map { |d| "#{root}/#{d}/" }
  end
end
