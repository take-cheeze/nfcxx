#!/usr/bin/env ruby
# The k1om assembler (GNU as 2.22, Intel's k1om target). --march=k1om selects the MIC instruction set and EM_K1OM.
# This is scripts/k1om-bin/as (bash) ported to Ruby: the same program with the same arguments.
exec(File.join(ENV["NFCXX_K1OM_ROOT"] || "/opt/k1om", "bin", "k1om-mpss-linux-as"), "--march=k1om", *ARGV)
