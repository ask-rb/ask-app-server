source "https://rubygems.org"

gemspec

gem "ostruct"

group :test do
  gem "minitest", "~> 5.25"
  gem "mocha", "~> 3.1"
  gem "rake", "~> 13.0"
  gem "simplecov", "~> 0.22"
end

# Local development against sibling gems (ask-rb monorepo). Only active when
# the siblings are present; in a standalone checkout (CI) the published gems
# declared in the gemspec are used instead.
monorepo = Dir.exist?(File.expand_path("../ask-core", __dir__))
if monorepo
  gem "ask-agent", path: "../ask-agent"
  gem "ask-core", path: "../ask-core"
  gem "ask-session-protocol", path: "../ask-session-protocol"
  gem "ask-tools", path: "../ask-tools"
  gem "ask-tools-shell", path: "../ask-tools-shell"
  gem "ask-llm-providers", path: "../ask-llm-providers"
  gem "ask-skills", path: "../ask-skills"
  gem "ask-schema", path: "../ask-schema"
  gem "ask-instrumentation", path: "../ask-instrumentation"
  gem "ask-sandbox-providers", path: "../ask-sandbox-providers"
  gem "ask-state-providers", path: "../ask-state-providers"
end
