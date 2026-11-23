require_relative "test_helper"
require "tmpdir"
require "pathname"

class ClaudeMediaTest < Minitest::Test
  def setup
    @client = AiLite::Claude.new(api_key: "test")
  end

  def test_local_binary_files_and_supported_mime_types
    Dir.mktmpdir do |dir|
      { "JPG" => "image/jpeg", "jpeg" => "image/jpeg", "png" => "image/png",
        "gif" => "image/gif", "webp" => "image/webp", "PDF" => "application/pdf" }.each do |ext, mime|
        path = File.join(dir, "sample.#{ext}")
        bytes = "\x00\xff\x80\n".b
        File.binwrite(path, bytes)
        method = ext == "PDF" ? :pdf_input : :image_input
        block = @client.public_send(method, path: Pathname.new(path))
        assert_equal ext == "PDF" ? "document" : "image", block["type"]
        assert_equal "base64", block["source"]["type"]
        assert_equal mime, block["source"]["media_type"]
        assert_equal bytes, block["source"]["data"].unpack("m0").first
        refute_includes block["source"]["data"], "\n"
      end
    end
  end

  def test_urls_metadata_and_class_helpers_need_no_key_or_network
    old_key = ENV.delete("ANTHROPIC_API_KEY")
    url = "https://example.com/download?id=1&signature=a%2Bb"
    title = "Report"
    image = AiLite::Claude.image_input(url: url)
    pdf = AiLite::Claude.pdf_input(url: url, title: title, citations: true)
    assert_equal({ "type" => "image", "source" => { "type" => "url", "url" => url } }, image)
    assert_equal "document", pdf["type"]
    assert_equal({ "enabled" => true }, pdf["citations"])
    assert_equal "Report", pdf["title"]
    image["source"]["url"].replace("changed")
    pdf["title"].replace("changed")
    assert_equal "Report", title
    assert_equal url, pdf["source"]["url"]
    refute @client.pdf_input(url: url).key?("citations")
    assert_equal false, @client.pdf_input(url: url, citations: false)["citations"]["enabled"]
  ensure
    ENV["ANTHROPIC_API_KEY"] = old_key
  end

  def test_invalid_sources_and_files
    [:image_input, :pdf_input].each do |method|
      [{}, { path: "x", url: "https://example.com" }, { path: "" }, { path: 1 },
       { url: "" }, { url: 1 }, { url: "not a url" }, { url: "file:///tmp/file" },
       { url: "https:///" }, { url: "https://user:pass@example.com/a" }].each do |args|
        assert_raises(ArgumentError) { @client.public_send(method, **args) }
      end
    end
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) { @client.image_input(path: File.join(dir, "missing.png")) }
      path = File.join(dir, "empty.pdf")
      File.binwrite(path, "")
      assert_raises(ArgumentError) { @client.pdf_input(path: path) }
      assert_raises(ArgumentError) { @client.image_input(path: path) }
      assert_raises(ArgumentError) { @client.pdf_input(path: dir) }
    end
    assert_raises(ArgumentError) { @client.pdf_input(url: "https://example.com", title: 1) }
    assert_raises(ArgumentError) { @client.pdf_input(url: "https://example.com", citations: "yes") }
  end
end
