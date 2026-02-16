# frozen_string_literal: true

require_relative "lib/hron/version"

Gem::Specification.new do |spec|
  spec.name = "hron"
  spec.version = Hron::VERSION
  spec.authors = ["Prasanna Venkataraman"]
  spec.email = ["prasrvenkat@gmail.com"]

  spec.summary = "Human-readable cron — a scheduling expression language that is a superset of cron"
  spec.description = "hron (human-readable cron) is a scheduling expression language " \
                     "that is designed to be easy to read, write, and understand. It is a superset of cron, " \
                     "meaning any valid cron expression can be converted to and from hron."
  spec.homepage = "https://github.com/prasrvenkat/hron"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/prasrvenkat/hron"
  spec.metadata["changelog_uri"] = "https://github.com/prasrvenkat/hron/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "tzinfo", "~> 2.0"

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "standard", "~> 1.43"
end
