# frozen_string_literal: true

require_relative "lib/hron/version"

Gem::Specification.new do |spec|
  spec.name = "hron"
  spec.version = Hron::VERSION
  spec.authors = ["Prasanna Venkataraman"]
  spec.email = ["pras@simpllyf.io"]

  spec.summary = "Human-readable cron — scheduling expressions that read like English and convert to and from cron"
  spec.description = "hron (human-readable cron) is a scheduling expression language " \
                     "that is designed to be easy to read, write, and understand. It converts to and from cron " \
                     "exactly where both can express a schedule, and expresses schedules cron cannot."
  spec.homepage = "https://hron.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/simpllyf/hron"
  spec.metadata["changelog_uri"] = "https://github.com/simpllyf/hron/releases"
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
end
