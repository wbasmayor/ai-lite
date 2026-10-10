require_relative "lib/ai_lite/version"

Gem::Specification.new do |spec|
  spec.name = "ai-lite"
  spec.version = AiLite::VERSION
  spec.authors = ["William Basmayor"]
  spec.summary = "Lightweight Ruby client with separate OpenAI and Gemini providers."
  spec.description = "AI Lite is a dependency-light Ruby client for Rails apps and plain Ruby projects, using only the Ruby standard library. It provides OpenAI chat, streaming, moderation, embeddings, images, speech, transcription, and model checks, plus Gemini chat, streaming, structured media inputs, and model checks."
  spec.homepage = "https://github.com/wbasmayor/ai-lite"
  spec.license = "MIT"
  spec.metadata["source_code_uri"] = spec.homepage
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
