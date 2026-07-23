# frozen_string_literal: true

require_relative "lib/ask/app_server/version"

Gem::Specification.new do |spec|
  spec.name = "ask-app-server"
  spec.version = Ask::AppServer::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@myrrlabs.com"]

  spec.summary = "JSON-RPC app-server for ask-rb agents"
  spec.description = "Exposes Ask::Agent::Session behind the standard app-server JSON-RPC/stdio protocol. " \
                     "Drop-in compatible with clients that speak the ZCode/Codex app-server protocol — " \
                     "Telegram bots, AI SDK providers, IDE extensions, and headless automation."

  spec.homepage = "https://github.com/ask-rb/ask-app-server"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.bindir = "bin"
  spec.executables = ["ask-app-server"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ask-agent", ">= 0.1"
  spec.add_dependency "ask-core", ">= 0.1"
  spec.add_dependency "ask-tools", ">= 0.1"
  spec.add_dependency "ask-tools-shell", ">= 0.1"
  spec.add_dependency "ask-state-providers", ">= 0.1"

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "ostruct"
end
