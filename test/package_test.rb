require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

class PackageTest < Minitest::Test
  def test_built_gem_loads_without_runtime_dependencies
    root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(root, "ai-lite.gemspec"))
    assert_empty spec.runtime_dependencies

    Dir.mktmpdir("ai-lite-package") do |dir|
      source = File.join(dir, "source")
      installed = File.join(dir, "installed")
      FileUtils.mkdir_p(source)
      (spec.files + ["ai-lite.gemspec"]).each do |file|
        destination = File.join(source, file)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(root, file), destination)
      end
      output, status = Open3.capture2e(RbConfig.ruby, "-rrubygems/gem_runner", "-e", "Gem::GemRunner.new.run(ARGV)", "--", "build", "ai-lite.gemspec", chdir: source)
      assert status.success?, output
      package = File.join(source, "ai-lite-#{spec.version}.gem")
      output, status = Open3.capture2e(RbConfig.ruby, "-rrubygems/gem_runner", "-e", "Gem::GemRunner.new.run(ARGV)", "--", "install", package,
                                     "--local", "--install-dir", installed, "--no-document", "--ignore-dependencies")
      assert status.success?, output

      %w[ai_lite ai_lite/openai ai_lite/gemini ai_lite/claude].each do |entry|
        output, status = Open3.capture2e(
          { "GEM_HOME" => installed, "GEM_PATH" => installed, "RUBYLIB" => nil, "RUBYOPT" => nil },
          RbConfig.ruby, "-e", <<~'RUBY', entry, installed, chdir: dir
            require ARGV.fetch(0)
            spec = Gem.loaded_specs.fetch("ai-lite")
            abort "Loaded outside isolated installation" unless File.realpath(spec.full_gem_path).start_with?(File.realpath(ARGV.fetch(1)) + "/")
            abort "Unexpected runtime dependencies" unless spec.runtime_dependencies.empty?
            [:OpenAI, :Gemini, :Claude].each do |name|
              next unless AiLite.const_defined?(name, false)
              client = AiLite.const_get(name).new(api_key: "package-test-key")
              methods = name == :Claude ? [:chat] : [:chat, :chat_stream, :embed, :image, :speak, :transcribe, :count_tokens, :configured_models]
              methods.each do |method|
                abort "Missing #{name}.#{method}" unless client.respond_to?(method)
              end
              abort "Missing chat model" unless client.model
            end
          RUBY
        )
        assert status.success?, "#{entry}: #{output}"
      end
    end
  end
end
