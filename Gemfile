# frozen_string_literal: true

# Host-side bc2cpp tools and checks (bc2cpp/tools/bc2cpp, bc2cpp/scripts/bc2cpp). They are written against Prism 1.x
# (`IfNode#subsequent`) and RBS 4.x (`TypeParam#upper_bound_type`). The system Ruby ships Prism 0.19 and RBS 3.4, which
# fail those checks. Versions match rpg-maker-clone's Gemfile, so both repositories resolve the same gems.
# Use: bundle exec ruby bc2cpp/scripts/bc2cpp/<check>.rb
source 'https://rubygems.org'

gem 'prism', '1.9.0'
gem 'rbs', '4.0.0'
gem 'rake', '13.4.2'

# bc2cpp's fixture checks that use minitest/autorun (bc2cpp/scripts/bc2cpp), and compiler_profile.rb's sampling profiler.
group :test do
  gem 'minitest', '5.26.2'
end

group :profile do
  gem 'stackprof', '0.2.28'
end
