require_relative "lib/ai_lite/version"

Gem::Specification.new do |spec|
  spec.name = "ai-lite"
  spec.version = AiLite::VERSION
  spec.authors = ["William Basmayor"]
  spec.summary = "Lightweight Ruby client with separate OpenAI and Gemini providers."
  spec.description = <<~DESCRIPTION.strip
    AI Lite is a lightweight Ruby client for OpenAI and Gemini, built for Rails apps and plain Ruby projects. It uses only Ruby's standard library and has no runtime gem dependencies.

    Both providers support chat, streaming, function calling, embeddings, image generation, speech, transcription, token counting, and model checks. OpenAI also supports moderation. Gemini also supports structured media inputs and a YouTube helper.
  DESCRIPTION
  spec.homepage = "https://github.com/wbasmayor/ai-lite"
  spec.license = "MIT"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.files = Dir[
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "lib/**/*.rb",
    "test/**/*.rb"
  ]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.6"
end
