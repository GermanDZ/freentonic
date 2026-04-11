Gem::Specification.new do |spec|
  spec.name          = "freentonic"
  spec.version       = File.read(File.expand_path("lib/freentonic/version.rb", __dir__))[/VERSION = "(.*?)"/, 1]
  spec.authors       = ["Freentonic contributors"]
  spec.summary       = "Declarative YAML-driven data provider scraper (connect → extract → normalize → export)"
  spec.description   = <<~DESC
    Freentonic is a pluggable, YAML-driven workflow framework for scraping
    personal-data providers (banks, brokers, utilities) by driving a real
    Chrome session via CDP, then normalizing and exporting the result through
    pluggable exporters (JSON, JSONL, CSV, HTTP). Zero runtime gem dependencies.
  DESC
  spec.homepage      = "https://github.com/GermanDZ/freentonic"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files         = Dir[
    "lib/**/*.rb",
    "bin/freentonic",
    "examples/**/*",
    "README.md",
    "SECURITY.md",
    "LICENSE"
  ]
  spec.bindir        = "bin"
  spec.executables   = ["freentonic"]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  # Runtime dependencies: none. Freentonic is pure stdlib by design.
end
