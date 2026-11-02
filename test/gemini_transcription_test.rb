require_relative "test_helper"
require "tmpdir"

class GeminiTranscriptionTest < Minitest::Test
  Response = Struct.new(:code, :body)

  def setup
    AiLite::Gemini.reset_configuration!
    @client = AiLite::Gemini.new(api_key: "key")
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "sample.WAV")
    File.binwrite(@path, "RIFF\x00\xff".b)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    AiLite::Gemini.reset_configuration!
  end

  def body(text = "Hello!")
    { "id" => "transcript-1", "status" => "completed", "steps" => [
      { "type" => "thought", "content" => [{ "type" => "text", "text" => "ignore" }] },
      { "type" => "model_output", "content" => [{ "type" => "text", "text" => text }] }
    ] }
  end

  def with_response(raw = body, code = "200")
    original = Net::HTTP.method(:start)
    test = self
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      test.assert_equal "generativelanguage.googleapis.com", host
      test.assert_equal 443, port
      test.assert use_ssl
      http = Object.new
      http.define_singleton_method(:open_timeout=) { |_| }
      http.define_singleton_method(:read_timeout=) { |_| }
      http.define_singleton_method(:request) do |request|
        test.instance_variable_set(:@request, request)
        raise raw if raw.is_a?(Exception)
        Response.new(code, raw.is_a?(String) ? raw : JSON.generate(raw))
      end
      block.call(http)
    end
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_transport_and_plain_text_envelope
    with_response(body('{"spoken":true}')) do
      result = @client.transcribe(@path)
      assert_equal({ "content" => '{"spoken":true}', "error" => nil, "status" => 200,
                     "response_id" => "transcript-1", "raw" => nil }, result)
      assert_equal "/v1beta/interactions", @request.path
      assert_equal "key", @request["x-goog-api-key"]
      payload = JSON.parse(@request.body)
      assert_equal "gemini-3.5-transcribe", payload["model"]
      assert_equal File.binread(@path), payload["input"][0]["data"].unpack1("m0")
      assert_equal "audio/wav", payload["input"][0]["mime_type"]
      refute payload.key?("generation_config")
    end
  end

  def test_configuration_delegation_options_and_debug
    AiLite::Gemini.configure { |c| c.api_key = "key"; c.transcription_model = "configured" }
    options = { model: "ignored", input: "ignored", store: false,
                generation_config: { transcription_config: { language_codes: ["en-US"] } } }
    before = Marshal.dump(options)
    with_response do
      result = AiLite::Gemini.transcribe(@path, options: options, debug: true)
      assert_nil result["error"]
      assert_equal body, result["raw"]
      payload = JSON.parse(@request.body)
      assert_equal "configured", payload["model"]
      assert_equal false, payload["store"]
      assert_equal ["en-US"], payload.dig("generation_config", "transcription_config", "language_codes")
    end
    assert_equal before, Marshal.dump(options)
    client = AiLite::Gemini.new(transcription_model: "constructor")
    assert_equal "constructor", client.configured_models["transcription"]
    with_response do
      client.transcribe(@path, model: "override", mime_type: "audio/l16;rate=24000")
      assert_equal "override", JSON.parse(@request.body)["model"]
      assert_equal "audio/l16;rate=24000", JSON.parse(@request.body).dig("input", 0, "mime_type")
    end
  end

  def test_invalid_inputs_do_not_send_requests
    [nil, "missing.wav", @dir].each do |path|
      assert_equal "unknown", @client.transcribe(path)["status"]
    end
    [ { options: nil }, { options: { stream: true } }, { options: { background: true } },
      { mime_type: "audio/unknown" } ].each do |args|
      refute_nil @client.transcribe(@path, **args)["error"]
    end
    File.binwrite(@path, "")
    assert_match(/empty/, @client.transcribe(@path)["error"])
    File.open(@path, "wb") { |file| file.truncate(15_000_001) }
    assert_match(/under 20 MB/, @client.transcribe(@path)["error"])
    File.binwrite(@path, "small")
    assert_match(/under 20 MB/, @client.transcribe(@path, options: { extra: "x" * 20_000_000 })["error"])
  end

  def test_errors_and_malformed_responses
    [ [403, { "error" => { "message" => "Denied" } }], [200, { "error" => "Oops" }],
      [200, []], [200, "invalid json"], [200, body.merge("status" => "failed")],
      [200, body.merge("status" => "in_progress")], [200, body.merge("steps" => [])],
      [200, body.merge("steps" => nil)], [200, IOError.new("Disconnected")] ].each do |code, raw|
      with_response(raw, code.to_s) do
        result = @client.transcribe(@path, debug: true)
        assert_nil result["content"]
        refute_nil result["error"]
      end
    end
  end

  def test_empty_transcript_and_multiple_text_parts
    with_response(body("")) { assert_equal "", @client.transcribe(@path)["content"] }
    raw = body("Hello ")
    raw["steps"].last["content"] << { "type" => "text", "text" => "world." }
    with_response(raw) { assert_equal "Hello world.", @client.transcribe(@path)["content"] }
  end
end
