#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# A block step compiled while the embedded-ivar layout is still being decided (it sits in a callee of an embedding #initialize)
# must be compiled again against the final layout: its read of an ivar that became a boxed slot would otherwise unbox a field
# that holds an mrb_value (g++: cannot convert 'mrb_value' to 'mrb_bool'). The output must equal the interpreted run.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_step_layout_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp block step layout check')

SRC = <<~'RUBY'
  # Its bool slot is demoted to a boxed one: #initialize reads @flag (through #flag) before it assigns it.
  class LayoutItem
    attr_reader :flag

    def initialize
      @seen = flag
      @flag = false
    end
  end

  class LayoutOther
    attr_reader :flag

    def initialize
      @flag = true
    end
  end

  # #initialize calls #scan, whose block is a step (it holds a Fiber.yield) and reads both classes' @flag.
  class LayoutZHolder
    def initialize(members)
      @members = members
      scan
    end

    def scan
      walk { |member| Fiber.yield member.flag; member }
    end

    def walk
      @members.each { |member| yield member }
    end
  end

  class LayoutProbe
    def run
      Fiber.new { LayoutZHolder.new([LayoutItem.new, LayoutOther.new]).class }
    end
  end
RUBY

OWNERS = %w[LayoutItem LayoutOther LayoutZHolder LayoutProbe].freeze
suite.generate(SRC, OWNERS)

DRIVER = Bc2cppStepCheck::SHOW + Bc2cppStepCheck::DRAIN + <<~'RUBY'
  show('block step reads a boxed ivar') { drain(LayoutProbe.new.run) }
  puts 'end'
RUBY

suite.behaviour(DRIVER, same: true)
suite.finish
