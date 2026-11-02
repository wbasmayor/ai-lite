require_relative "test_helper"

class TokenCountingTest < Minitest::Test
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
    [AiLite::OpenAI, AiLite::Gemini].each(&:reset_configuration!)
  end

  def teardown
    [AiLite::OpenAI, AiLite::Gemini].each(&:reset_configuration!)
  end

  def providers
    [[AiLite::OpenAI, "input_tokens", "api.openai.com", "/v1/responses/input_tokens"],
     [AiLite::Gemini, "totalTokens", "generativelanguage.googleapis.com", "/v1beta/models/chosen:countTokens"]]
  end

  def with_http(raw, code = "200")
    http = Http.new(raw.is_a?(Exception) ? raw : Response.new(code, raw.is_a?(String) ? raw : JSON.generate(raw)))
    original = Net::HTTP.method(:start)
    test = self
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      test.instance_variable_set(:@host, host)
      test.assert_equal 443, port
      test.assert use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_default_transport_and_standard_envelope
    providers.each do |provider, field, host, path|
      client = provider.new(api_key: "provider-key", model: "chosen", timeout: 7, max_output_tokens: 99)
      with_http({ field => 12 }) do |http|
        assert_equal({ "content" => 12, "error" => nil, "response_id" => nil, "raw" => nil, "status" => 200 }, client.count_tokens("Hello"))
        assert_equal host, @host
        assert_instance_of Net::HTTP::Post, http.request_received
        assert_equal path, http.request_received.path
        assert_equal "application/json", http.request_received["Content-Type"]
        assert_equal 7, http.open_timeout
        assert_equal 7, http.read_timeout
        payload = JSON.parse(http.request_received.body)
        if provider == AiLite::OpenAI
          assert_equal "Bearer provider-key", http.request_received["Authorization"]
          assert_nil http.request_received["x-goog-api-key"]
          assert_equal({ "model" => "chosen", "input" => "Hello" }, payload)
        else
          assert_equal "provider-key", http.request_received["x-goog-api-key"]
          assert_nil http.request_received["Authorization"]
          assert_equal({ "contents" => [{ "parts" => [{ "text" => "Hello" }] }] }, payload)
        end
      end
    end
  end

  def test_zero_debug_and_class_configuration
    providers.each do |provider, field, _, _|
      provider.configure { |c| c.api_key = "key"; c.model = "configured" }
      assert_equal "configured", provider.client.model
      with_http({ field => 0, "details" => { "cached" => 0 } }) do |http|
        result = provider.count_tokens("", debug: true, model: "override")
        assert_equal 0, result["content"]
        assert_nil result["error"]
        assert_equal({ field => 0, "details" => { "cached" => 0 } }, result["raw"])
        if provider == AiLite::OpenAI
          assert_equal "override", JSON.parse(http.request_received.body)["model"]
        else
          assert_equal "/v1beta/models/override:countTokens", http.request_received.path
        end
      end
    end
    assert_equal "configured", AiLite::OpenAI.configuration.model
  end

  def test_openai_history_media_instructions_and_native_options
    input = [{ role: "user", content: [{ type: "input_text", text: "Describe" },
                                       { type: "input_image", image_url: "https://example.com/a.png" }] }]
    options = { "model" => "ignored", input: "ignored", instructions: "ignored",
                previous_response_id: "ignored", tools: [{ type: "function", name: "lookup", parameters: {} }] }
    original = Marshal.dump([input, options])
    with_http({ "input_tokens" => 100 }) do |http|
      result = AiLite::OpenAI.new(api_key: "key").count_tokens(input, model: "selected", instructions: "Be concise",
                                                              previous_response_id: "resp_123", options: options)
      assert_nil result["error"]
      payload = JSON.parse(http.request_received.body)
      assert_equal "selected", payload["model"]
      assert_equal JSON.parse(JSON.generate(input)), payload["input"]
      assert_equal "Be concise", payload["instructions"]
      assert_equal "resp_123", payload["previous_response_id"]
      assert_equal "lookup", payload.dig("tools", 0, "name")
    end
    assert_equal original, Marshal.dump([input, options])
  end

  def test_gemini_history_media_and_nested_native_options
    input = [{ role: "user", parts: [{ text: "Hello" }] }, { role: "model", parts: [{ text: "Hi" }] },
             { role: "user", parts: [{ inlineData: { mimeType: "image/png", data: "AAAA" } }] }]
    options = { contents: "ignored", generateContentRequest: { model: "ignored", contents: [],
                systemInstruction: { parts: [{ text: "ignored" }] }, tools: [{ functionDeclarations: [{ name: "lookup" }] }] } }
    original = Marshal.dump([input, options])
    with_http({ "totalTokens" => 100 }) do |http|
      result = AiLite::Gemini.new(api_key: "key").count_tokens(input, model: "models/selected", instructions: "Be concise", options: options)
      assert_nil result["error"]
      assert_equal "/v1beta/models/selected:countTokens", http.request_received.path
      payload = JSON.parse(http.request_received.body)
      refute payload.key?("contents")
      assert_equal "models/selected", payload.dig("generateContentRequest", "model")
      assert_equal JSON.parse(JSON.generate(input)), payload.dig("generateContentRequest", "contents")
      assert_equal "Be concise", payload.dig("generateContentRequest", "systemInstruction", "parts", 0, "text")
      assert_equal "lookup", payload.dig("generateContentRequest", "tools", 0, "functionDeclarations", 0, "name")
    end
    assert_equal original, Marshal.dump([input, options])
    with_http({ "totalTokens" => 5 }) do |http|
      AiLite::Gemini.new(api_key: "key").count_tokens({ parts: [{ text: "Hi" }] }, instructions: "Be brief")
      assert_equal "Hi", JSON.parse(http.request_received.body).dig("generateContentRequest", "contents", 0, "parts", 0, "text")
    end
  end

  def test_api_errors_invalid_counts_and_raw_visibility
    providers.each do |provider, field, _, _|
      client = provider.new(api_key: "key")
      [ ["429", { "error" => { "message" => "Rate limited" } }], ["200", { "error" => "Failed" }],
        ["200", []], ["200", "not json"], ["200", {}], ["200", { field => -1 }],
        ["200", { field => 1.5 }], ["200", { field => "12" }], ["200", { field => nil }],
        ["200", IOError.new("Disconnected")] ].each do |code, raw|
        with_http(raw, code) do
          result = client.count_tokens("Hello", debug: true)
          assert_nil result["content"]
          refute_nil result["error"]
          assert_equal(raw.is_a?(Exception) ? "unknown" : code.to_i, result["status"])
          assert_equal raw, result["raw"] unless raw.is_a?(Exception)
        end
      end
      with_http({ "error" => { "message" => "Denied" } }, "403") do
        result = client.count_tokens("Hello")
        assert_equal "Denied", result["error"]
        assert_nil result["raw"]
      end
    end
  end

  def test_invalid_inputs_never_make_a_request
    with_http(RuntimeError.new("Unexpected network call")) do |http|
      providers.each do |provider, _, _, _|
        client = provider.new(api_key: "key")
        [nil, 12, ["text"]].each { |input| refute_nil client.count_tokens(input)["error"] }
        refute_nil client.count_tokens("Hello", options: nil)["error"]
        refute_nil client.count_tokens("Hello", instructions: 1)["error"]
      end
      gemini = AiLite::Gemini.new(api_key: "key")
      ["../bad", "name?key=x", "", 12].each { |model| refute_nil gemini.count_tokens("Hi", model: model)["error"] }
      refute_nil gemini.count_tokens({ type: "text", text: "Interactions format" })["error"]
      refute_nil gemini.count_tokens("Hi", options: { generateContentRequest: nil })["error"]
      refute_nil gemini.count_tokens("Hi", options: { previous_interaction_id: "id" })["error"]
      assert_nil http.request_received
    end
  end
end
