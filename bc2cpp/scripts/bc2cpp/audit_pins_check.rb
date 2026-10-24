#!/usr/bin/env ruby
# frozen_string_literal: true

# AUDIT_PINS: the native and foreign-Ruby audits bc2cpp trusts (NativeIvarScopes, NativeClassResults,
# ForeignStringResults) pin each audited file by SHA-256 and quietly stop counting it once the file changes, so an
# ordinary edit of lib.cxx or an mruby bump withdraws every fact the file backs with nothing failing. This check fails
# instead: re-read the change against the audit's claims, then add the new digest (or fix the audit).
#
#   ruby scripts/bc2cpp/audit_pins_check.rb
require 'digest'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/native_ivar_scopes'
require_relative '../../tools/bc2cpp/native_class_results'
require_relative '../../tools/bc2cpp/foreign_string_results'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('audit_pins_check')

# [table, path relative to ROOT, accepted digests]
pins = NativeIvarScopes::FILES.map { |rel, digest| ['NativeIvarScopes::FILES', rel, Array(digest)] } +
       NativeClassResults::FILES.map { |rel, digest| ['NativeClassResults::FILES', rel, Array(digest)] } +
       [['NativeClassResults::STRUCT_ALIAS_SHA', NativeClassResults::STRUCT_ALIAS_PATH, [NativeClassResults::STRUCT_ALIAS_SHA]]] +
       ForeignStringResults::AUDITED.map { |rel, (*_names, digest)| ['ForeignStringResults::AUDITED', "3rd/mruby/#{rel}", [digest]] }

pins.each do |table, rel, digests|
  path = File.join(ROOT, rel)
  current = File.file?(path) ? Digest::SHA256.file(path).hexdigest : 'missing'
  suite.check("#{table} #{rel} matches its pin (now #{current})", digests.include?(current))
end

suite.finish!
