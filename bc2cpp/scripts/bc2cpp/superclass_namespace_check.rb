#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPERCLASS_NAMESPACE (tools/bc2cpp/registry.rb, settle_superclass_names): a bare superclass constant written inside a
# namespace is the innermost enclosing definition of that name, or the top-level one when no enclosing namespace defines
# it, as Ruby's lexical lookup resolves it. A wrong superclass would send a direct super to the wrong method.
# Needs MRBC; without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/superclass_namespace_check.rb

require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('superclass_namespace_check')
suite.require_mrbc!

SRC = <<~'RUBY'
  module RGSS
    class Bitmap
      class LoadError < RuntimeError
      end
    end

    class RGSSError < StandardError
    end

    class Error < RGSSError
    end
  end

  class Error
  end

  class Sub < Error
  end
RUBY

suite.compile(SRC) do |ireps, root|
  supers = build_registry(ireps, root)[1]
  suite.check('a superclass no enclosing namespace defines is the top-level class', supers['RGSS::Bitmap::LoadError'] == 'RuntimeError')
  suite.check('a superclass the enclosing namespace defines is that class', supers['RGSS::Error'] == 'RGSS::RGSSError')
  suite.check('a superclass only the top level defines is the top-level class (Sub is not under RGSS)', supers['Sub'] == 'Error')
  suite.check('a namespaced superclass the namespace does not define is the top-level one', supers['RGSS::RGSSError'] == 'StandardError')
end

suite.finish!
