require_relative "lib/ai_lite/version"

Gem::Specification.new do |spec|
  spec.name = "ai-lite"
  spec.version = AiLite::VERSION
  spec.authors = ["William Basmayor"]
  spec.summary = "Minimal Ruby client for simple OpenAI API calls."
  spec.description = "AI Lite is a dependency-light Ruby client for Rails apps and plain Ruby projects that need simple OpenAI chat, moderation, embedding, image, speech, and transcription calls."
  spec.homepage = "https://github.com/wbasmayor/ai-lite"
  spec.license = "MIT"
  spec.files = Dir[
    "README.md",
    "LICENSE",
    "lib/**/*.rb",
    "test/**/*.rb"
  ]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.6"
end
