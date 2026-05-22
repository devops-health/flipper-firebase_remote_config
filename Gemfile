source 'https://rubygems.org'

gemspec

# Lint / audit tooling. CI installs these only on the newest Ruby; the test
# matrix sets BUNDLE_WITHOUT=development to skip them, so older Rubies don't
# have to satisfy rubocop's ever-rising runtime floor.
group :development do
  gem 'bundler-audit', '~> 0.9'
  gem 'rubocop', '~> 1.60'
end

group :test do
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.12'
  gem 'webmock', '~> 3.19'
end
