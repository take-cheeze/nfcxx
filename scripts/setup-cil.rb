#!/usr/bin/env ruby
# Fetch the ILAssembler the CIL backend (NFCXX_BACKEND=cil) writes its program with, into build/cil/ilasm. The binary is
# the native ilasm from the dotnet/runtime tooling, on NuGet: runtime.linux-x64.microsoft.netcore.ilasm for x86-64 and
# runtime.linux-arm64.microsoft.netcore.ilasm for aarch64 (same version, same layout in the package). The .NET runtime
# that runs the program is separate: install the .NET 8 (or later) runtime, `dotnet` on PATH.
require_relative "setup-common"
include SetupCommon

ver = "10.0.13"
root = root_of(__FILE__)
dest = "#{root}/build/cil"
must("mkdir", "-p", dest)
if File.executable?("#{dest}/ilasm")
  puts "ok: #{dest}/ilasm"
  exit 0
end
rid = case chomp_all(capture("uname", "-m")[0])
      when "x86_64", "amd64" then "linux-x64"
      when "aarch64", "arm64" then "linux-arm64"
      else
        die("setup-cil: no ilasm package for #{chomp_all(capture('uname', '-m')[0])}")
      end
unless chomp_all(capture("uname", "-s")[0]) == "Linux"
  die("setup-cil: the ilasm package is a Linux binary (#{chomp_all(capture('uname', '-s')[0])} host)")
end

with_tmp do |tmp|
  pkg = "runtime.#{rid}.microsoft.netcore.ilasm"
  must("curl", "-sSfL", "-o", "#{tmp}/ilasm.nupkg",
       "https://api.nuget.org/v3-flatcontainer/#{pkg}/#{ver}/#{pkg}.#{ver}.nupkg")
  must("python3", "-c",
       "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract('runtimes/#{rid}/native/ilasm', sys.argv[2])",
       "#{tmp}/ilasm.nupkg", tmp)
  must("install", "-m", "755", "#{tmp}/runtimes/#{rid}/native/ilasm", "#{dest}/ilasm")
  puts "ok: #{dest}/ilasm (#{pkg} #{ver})"
end
