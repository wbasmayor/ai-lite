require_relative "test_helper"
require "tmpdir"

class GeminiImagesTest < Minitest::Test
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

  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")

  def image_body
    { "id" => "image-123", "status" => "completed", "steps" => [
      { "type" => "thought", "content" => [{ "type" => "image", "data" => Base64.strict_encode64("hidden") }] },
      { "type" => "model_output", "content" => [
        { "type" => "text", "text" => "Here is your image" },
        { "type" => "image", "mime_type" => "image/png", "data" => Base64.strict_encode64(PNG) },
        { "type" => "image", "mime_type" => "image/png", "data" => Base64.strict_encode64("second") }
      ] }
    ] }
  end

  def test_default_transport_first_image_and_envelope
    with_http(image_body) do |http|
      result = @client.image("A cat")
      assert_equal({ "content" => Base64.strict_encode64(PNG), "status" => 200,
                     "error" => nil, "response_id" => "image-123", "raw" => nil }, result)
      request = http.request_received
      assert_equal "/v1beta/interactions", request.path
      assert_equal "gemini-key", request["x-goog-api-key"]
      assert_equal "application/json", request["Content-Type"]
      assert_equal({ "model" => AiLite::Gemini::DEFAULT_IMAGE_MODEL, "input" => "A cat" }, JSON.parse(request.body))
      assert_equal 9, http.open_timeout
      assert_equal 9, http.read_timeout
    end
  end

  def test_native_options_precedence_debug_and_file_output
    options = { model: "ignored", "input" => "ignored", response_format: { type: "image", aspect_ratio: "16:9", image_size: "2K" }, store: false }
    original = Marshal.dump(options)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cat.png")
      with_http(image_body) do |http|
        result = @client.image("A cat", model: "custom-image", output_path: path, options: options, debug: true)
        assert_nil result["error"]
        assert_equal PNG, File.binread(path)
        assert_equal Base64.strict_encode64(PNG), result["content"]
        assert_equal image_body, result["raw"]
        payload = JSON.parse(http.request_received.body)
        assert_equal "custom-image", payload["model"]
        assert_equal "A cat", payload["input"]
        assert_equal false, payload["store"]
        assert_equal "16:9", payload.dig("response_format", "aspect_ratio")
        assert_equal "2K", payload.dig("response_format", "image_size")
        refute payload.key?("generation_config")
      end
    end
    assert_equal original, Marshal.dump(options)
  end

  def test_configuration_delegation_and_model_checks
    AiLite::Gemini.configure { |c| c.api_key = "key"; c.image_model = "configured-image" }
    assert_equal "configured-image", AiLite::Gemini.client.image_model
    assert_equal AiLite::Gemini::DEFAULT_IMAGE_MODEL, @client.image_model
    assert_equal "override", AiLite::Gemini.new(image_model: "override").image_model
    original = AiLite::OpenAI.configured_models
    snapshot = AiLite::Gemini.configured_models
    snapshot["image"].replace("changed")
    assert_equal "configured-image", AiLite::Gemini.configuration.image_model
    with_http(image_body) do |http|
      assert_nil AiLite::Gemini.image("A cat")["error"]
      assert_equal "configured-image", JSON.parse(http.request_received.body)["model"]
    end
    with_http({ "models" => [{ "name" => "models/configured-image" }] }) do
      assert_equal true, AiLite::Gemini.check_configured_models.dig("content", "image", "available")
    end
    assert_equal original, AiLite::OpenAI.configured_models
  end

  def test_invalid_inputs_and_execution_modes_do_not_send_requests
    with_http do |http|
      [nil, " ", [], {}].each { |prompt| refute_nil @client.image(prompt)["error"] }
      [{ stream: true }, { "background" => true }].each do |options|
        refute_nil @client.image("A cat", options: options)["error"]
      end
      assert_nil http.request_received
    end
  end

  def test_errors_do_not_overwrite_output
    malformed = image_body
    malformed["steps"][1]["content"][1]["data"] = "invalid base64!"
    no_image = image_body.merge("steps" => [{ "type" => "model_output", "content" => [{ "type" => "text", "text" => "Cannot generate" }] }])
    responses = [malformed, no_image, "invalid JSON", [], {}, IOError.new("Disconnected")]
    %w[failed incomplete cancelled requires_action queued in_progress].each do |state|
      responses << image_body.merge("status" => state)
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "existing.png")
      File.binwrite(path, "original")
      responses.each do |raw|
        with_http(raw) do
          result = @client.image("A cat", output_path: path)
          refute_nil result["error"]
          assert_nil result["content"]
          assert_nil result["raw"]
          assert_equal "original", File.binread(path)
        end
      end
      with_http(image_body) do
        result = @client.image("A cat", output_path: File.join(dir, "missing", "cat.png"), debug: true)
        refute_nil result["error"]
        assert_equal "image-123", result["response_id"]
        assert_equal image_body, result["raw"]
      end
    end
    ["403", "200"].each do |status|
      with_http({ "error" => { "message" => "Denied" } }, status) do
        result = @client.image("A cat", debug: true)
        assert_equal "Denied", result["error"]
        assert_equal status.to_i, result["status"]
        refute_nil result["raw"]
      end
    end
  end
end
