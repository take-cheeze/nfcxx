# frozen_string_literal: true

# The C++ compiler a check builds with: CXX when set, else nfcxx (the repository's ./nfcxx, with the EDG front end and QBE
# built by scripts/setup-edg.sh and scripts/setup-qbe.sh), else +fallback+. bc2cpp sits in nfcxx's checkout (bc2cpp/), or
# in rpg-maker-clone's 3rd/nfcxx/bc2cpp, so ../nfcxx is the driver either way.
module HostCxx
  NFCXX = File.expand_path('../../../nfcxx', __dir__)

  module_function

  def nfcxx?(cxx)
    File.basename(cxx.to_s.split.first.to_s) == 'nfcxx'
  end

  # nfcxx needs its EDG front end and a back end that is built. The Path B harness is optional (nfcxx falls back to qbe).
  def nfcxx_ready?
    root = File.dirname(NFCXX)
    File.executable?(NFCXX) && File.executable?(File.join(root, 'build/edg/bin/eccp')) &&
      File.executable?(File.join(root, 'build/qbe/qbe'))
  end

  def pick(fallback)
    explicit = ENV.fetch('CXX', '')
    return explicit unless explicit.empty?

    nfcxx_ready? ? NFCXX : fallback
  end
end
