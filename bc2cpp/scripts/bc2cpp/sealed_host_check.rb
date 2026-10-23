#!/usr/bin/env ruby
# frozen_string_literal: true

# RPG2K_SEALED_HOST must mean the same thing in the three places that use it: the CMake option that defines
# it on the desktop executable, the `--script` fence in src/main.cxx, and the closed-world guard that reads the
# fence (tools/bc2cpp/compiled_gems.rb's bc2cpp_sealed_host_text). Each assertion names the place it checks.

require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)
check = lambda do |label, condition|
  raise label unless condition

  puts "ok #{label}"
end

cmake = File.read(File.join(ROOT, 'CMakeLists.txt'), encoding: 'UTF-8')
check.call('CMake declares the RPG2K_SEALED_HOST option, default OFF',
           cmake.match?(/option\(RPG2K_SEALED_HOST\b[^)]*\bOFF\)/m))
check.call('CMake defines RPG2K_SEALED_HOST on the desktop executable only when the option is on',
           cmake.include?('if(RPG2K_SEALED_HOST)') &&
           cmake.include?('target_compile_definitions(${PROJECT_NAME} PRIVATE RPG2K_SEALED_HOST)'))

main = File.read(File.join(ROOT, 'src/main.cxx'), encoding: 'UTF-8')
fence = main[/^#ifdef RPG2K_SEALED_HOST\n(.*?)^#else\n/m, 1]
check.call('src/main.cxx fences the --script loader under #ifdef RPG2K_SEALED_HOST, with #else',
           !fence.nil?)
check.call('the sealed arm refuses --script with a CHECK',
           fence.to_s.include?('CHECK(FLAGS_script.empty())'))
check.call('the open arm still holds the --script loader',
           main.include?('mrb_load_string(M, str.c_str());'))

sealed = bc2cpp_sealed_host_text(main)
check.call('the closed-world guard drops the --script loader from a sealed host',
           !sealed.include?('mrb_load_string(M, str.c_str());'))
check.call('the guard keeps the sealed arm itself',
           sealed.include?('CHECK(FLAGS_script.empty())'))
