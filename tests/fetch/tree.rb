#!/usr/bin/env ruby
# frozen_string_literal: true

# One line per entry under ROOT, sorted by path: type (f, d, l), mode, size, sha256 (files) or the target (links), and the
# path relative to ROOT. The symlinks themselves are listed, not followed. tests/fetch/run.sh diffs these manifests.
require 'digest'
require 'find'

root = ARGV.fetch(0)
rows = []
Find.find(root) do |p|
  next if p == root

  rel = p.delete_prefix("#{root}/")
  st = File.lstat(p)
  mode = format('%o', st.mode & 0o7777)
  if st.symlink?
    rows << ['l', mode, '-', "-> #{File.readlink(p)}", rel]
  elsif st.directory?
    rows << ['d', mode, '-', '-', rel]
  else
    rows << ['f', mode, st.size, Digest::SHA256.file(p).hexdigest, rel]
  end
end
rows.sort_by(&:last).each { |row| puts row.join(' ') }
