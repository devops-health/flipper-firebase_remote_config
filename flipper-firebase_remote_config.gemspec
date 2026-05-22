require_relative 'lib/flipper/adapters/firebase_remote_config/version'

Gem::Specification.new do |spec|
  spec.name        = 'flipper-firebase_remote_config'
  spec.version     = Flipper::Adapters::FirebaseRemoteConfig::VERSION
  spec.authors     = ["Roberto Quintanilla"]
  spec.email       = ["roberto.quintanilla@gmail.com"]
  spec.summary     = 'Flipper adapter backed by Firebase Remote Config.'
  spec.description = 'Stores Flipper features as Firebase Remote Config parameters, ' \
                     'reading and writing via the Firebase Remote Config REST API.'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.0'

  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'flipper', '>= 1.0', '< 2.0'
  spec.add_dependency 'googleauth', '>= 1.0'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.60'
  spec.add_development_dependency 'webmock', '~> 3.19'
end
