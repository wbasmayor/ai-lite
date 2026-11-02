require_relative "test_helper"
require "tmpdir"

class GeminiSpeechTest < Minitest::Test
  Response = Struct.new(:code, :body)
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :request_received
    def initialize(response)
      @response = response
    end
    def request(request)
      @request_received = request
      raise @response if @response.is_a?(Exception)
      @response
    end
  end

  def setup
    AiLite::Gemini.reset_configuration!
    AiLite::OpenAI.reset_configuration!
    @client = AiLite::Gemini.new(api_key: "gemini-key", timeout: 9)
  end

  def with_http(raw = {}, status = "200")
    response = raw.is_a?(Exception) ? raw : Response.new(status, raw.is_a?(String) ? raw : JSON.generate(raw))
    http = Http.new(response)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong provider host" unless host == "generativelanguage.googleapis.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  PCM = "\x00\x00\xff\x7f".b
  WAV = "RIFF".b + [36 + PCM.bytesize].pack("V") + "WAVEfmt ".b +
        [16, 1, 1, 24000, 48000, 2, 16].pack("VvvVVvv") + "data".b + [PCM.bytesize].pack("V") + PCM

  def speech_body(bytes = WAV, mime = "audio/wav")
    { "id" => "speech-123", "status" => "completed", "steps" => [
      { "type" => "thought", "content" => [{ "type" => "audio", "data" => "ignored" }] },
      { "type" => "model_output", "content" => [
        { "type" => "text", "text" => "Here is the audio" },
        { "type" => "audio", "mime_type" => mime, "data" => [bytes].pack("m0") }
      ] }
    ], "usage" => { "total_tokens" => 5 } }
  end

  def test_default_payload_transport_and_binary_envelope
    with_http(speech_body) do |http|
      result = @client.speak("Hello")
      assert_equal({ "content" => WAV, "status" => 200, "error" => nil, "raw" => nil,
                     "response_id" => "speech-123" }, result)
      assert_equal Encoding::BINARY, result["content"].encoding
      request = http.request_received
      assert_equal "/v1beta/interactions", request.path
      assert_equal "gemini-key", request["x-goog-api-key"]
      assert_equal 9, http.read_timeout
      payload = JSON.parse(request.body)
      assert_equal "gemini-3.8-flash-tts", payload["model"]
      assert_equal [{ "type" => "user_input", "content" => [{ "type" => "text", "text" => "Hello" }] }], payload["input"]
      assert_equal({ "speech_config" => [{ "voice" => "Kore" }] }, payload["generation_config"])
      assert_equal({ "type" => "audio", "mime_type" => "audio/wav" }, payload["response_format"])
    end
  end

  def test_keywords_native_options_precedence_and_no_mutation
    options = { "model" => "ignored", input: "ignored", store: false,
                generation_config: { temperature: 0.5, speech_config: [{ voice: "ignored" }] },
                response_format: { type: "text", mime_type: "audio/wav", sample_rate: 16000 } }
    original = Marshal.dump(options)
    with_http(speech_body(PCM, "audio/l16;rate=16000")) do |http|
      result = @client.speak("Hello", model: "custom-tts", voice: "Puck", instructions: "Speak calmly",
                             response_format: "pcm", options: options, debug: true)
      assert_equal PCM, result["content"]
      assert_equal 5, result.dig("raw", "usage", "total_tokens")
      payload = JSON.parse(http.request_received.body)
      assert_equal "custom-tts", payload["model"]
      assert_equal false, payload["store"]
      assert_equal [{ "voice" => "Puck" }], payload.dig("generation_config", "speech_config")
      assert_equal 0.5, payload.dig("generation_config", "temperature")
      refute payload["generation_config"].key?("max_output_tokens")
      assert_equal [{ "type" => "speech_metadata", "style" => "Speak calmly" }], payload.dig("input", 0, "content", 0, "annotations")
      assert_equal({ "type" => "audio", "mime_type" => "audio/l16", "sample_rate" => 16000 }, payload["response_format"])
    end
    assert_equal original, Marshal.dump(options)
  end

  def test_file_output_and_base64_priority
    Dir.mktmpdir do |dir|
      path = File.join(dir, "speech.wav")
      with_http(speech_body) do
        result = @client.speak("Hello", output_path: path)
        assert_equal({ "path" => path, "bytes" => WAV.bytesize, "format" => "wav" }, result["content"])
        assert_equal WAV, File.binread(path)
      end
      with_http(speech_body) do
        result = @client.speak("Hello", output_path: path, base64: true)
        assert_equal [WAV].pack("m0"), result["content"]
        assert_equal WAV, File.binread(path)
      end
      with_http(speech_body) do
        result = @client.speak("Hello", output_path: File.join(dir, "missing", "speech.wav"), debug: true)
        refute_nil result["error"]
        assert_nil result["content"]
        assert_equal "speech-123", result["response_id"]
        refute_nil result["raw"]
      end
    end
    with_http(speech_body) { assert_equal [WAV].pack("m0"), @client.speak("Hello", base64: true)["content"] }
  end

  def test_supported_formats_and_native_format_option
    { "pcm" => "audio/l16", "mulaw" => "audio/mulaw", "alaw" => "audio/alaw" }.each do |format, mime|
      with_http(speech_body(PCM, mime)) do |http|
        assert_equal PCM, @client.speak("Hello", response_format: format)["content"]
        assert_equal mime, JSON.parse(http.request_received.body).dig("response_format", "mime_type")
      end
    end
    with_http(speech_body(PCM, "audio/l16")) do |http|
      assert_nil @client.speak("Hello", options: { response_format: { mime_type: "audio/l16" } })["error"]
      assert_equal "audio/l16", JSON.parse(http.request_received.body).dig("response_format", "mime_type")
    end
  end

  def test_configuration_class_delegation_and_model_checks
    original = AiLite::OpenAI.configured_models
    AiLite::Gemini.configure { |c| c.api_key = "key"; c.speech_model = "configured-tts"; c.speech_voice = "Puck" }
    assert_equal "Kore", @client.speech_voice
    assert_equal "gemini-3.8-flash-tts", @client.speech_model
    override = AiLite::Gemini.new(speech_model: "override", speech_voice: "Zephyr")
    assert_equal ["override", "Zephyr"], [override.speech_model, override.speech_voice]
    snapshot = AiLite::Gemini.configured_models
    snapshot["speech"].replace("changed")
    assert_equal "configured-tts", AiLite::Gemini.configuration.speech_model
    with_http(speech_body) do |http|
      assert_equal WAV, AiLite::Gemini.speak("Hello")["content"]
      payload = JSON.parse(http.request_received.body)
      assert_equal "configured-tts", payload["model"]
      assert_equal [{ "voice" => "Puck" }], payload.dig("generation_config", "speech_config")
    end
    with_http({ "models" => [{ "name" => "models/configured-tts" }] }) do
      assert_equal true, AiLite::Gemini.check_configured_models.dig("content", "speech", "available")
    end
    assert_equal original, AiLite::OpenAI.configured_models
  end

  def test_invalid_inputs_rejected_before_http
    with_http do |http|
      [nil, " ", [], {}].each { |value| refute_nil @client.speak(value)["error"] }
      [{ voice: "" }, { instructions: [] }, { response_format: "mp3" }, { options: nil },
       { options: { stream: true } }, { options: { "background" => true } },
       { options: { generation_config: [] } }, { options: { response_format: nil } },
       { options: { response_format: { mime_type: "audio/mpeg" } } }].each do |kwargs|
        refute_nil @client.speak("Hello", **kwargs)["error"]
      end
      assert_nil http.request_received
    end
  end

  def test_errors_and_malformed_audio_preserve_existing_file
    bad_data = speech_body
    bad_data["steps"][1]["content"][1]["data"] = "invalid!"
    missing_data = speech_body
    missing_data["steps"][1]["content"][1].delete("data")
    many = speech_body
    many["steps"][1]["content"] << many["steps"][1]["content"][1].dup
    responses = ["bad JSON", [], {}, IOError.new("Disconnected"), bad_data, missing_data, many,
                 speech_body("", "audio/wav"), speech_body("not wav"), speech_body(PCM, "audio/unknown"),
                 speech_body.merge("steps" => []), speech_body.merge("steps" => nil)]
    %w[failed incomplete cancelled requires_action queued in_progress].each do |state|
      responses << speech_body.merge("status" => state)
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "existing.wav")
      File.binwrite(path, "original")
      responses.each do |raw|
        with_http(raw) do
          result = @client.speak("Hello", output_path: path)
          refute_nil result["error"]
          assert_nil result["content"]
          assert_nil result["raw"]
          assert_equal "original", File.binread(path)
        end
      end
    end
    %w[403 200].each do |status|
      with_http({ "error" => { "message" => "Denied" } }, status) do
        result = @client.speak("Hello", debug: true)
        assert_equal "Denied", result["error"]
        assert_equal status.to_i, result["status"]
        refute_nil result["raw"]
      end
    end
  end
end
