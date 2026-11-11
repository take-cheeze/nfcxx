# frozen_string_literal: true

require 'fileutils'

module OptcarrotOnigAliases
  NAMES = %w[sub gsub split scan].freeze
  LOOP = <<~'RUBY'.freeze
      %i[sub gsub split scan].each do |v|
        alias_method :"string_#{v}", v if method_defined?(v)
        alias_method v, :"onig_regexp_#{v}"
      end
  RUBY

  def self.transform(source)
    # Match the complete upstream loop so new installers cannot escape the scan.
    pattern = LOOP.lines.map { |line| "  #{line}" }.join
    raise 'OnigRegexp alias loop changed' unless source.scan(pattern).length == 1

    replacement = NAMES.map do |name|
      "  alias_method :string_#{name}, :#{name} if method_defined?(:#{name})\n" \
        "  alias_method :#{name}, :onig_regexp_#{name}\n"
    end.join
    source.sub(pattern, replacement)
  end

  def self.prepare(root, temp)
    target = File.join(temp, 'mruby-onig-regexp')
    FileUtils.cp_r(File.join(root, '3rd/mruby-onig-regexp'), target)
    ruby = File.join(target, 'mrblib/onig_regexp.rb')
    File.write(ruby, transform(File.read(ruby)))
    target
  end
end
