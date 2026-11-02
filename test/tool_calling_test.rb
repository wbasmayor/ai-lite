require_relative "test_helper"

class ToolCallingTest < Minitest::Test
  Response = Struct.new(:code, :body) do
    def read_body
      body.bytes.each_slice(7) { |bytes| yield bytes.pack("C*") }
    end
  end
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :requests
    def initialize(responses)
      @responses, @requests = responses, []
    end
    def request(request)
      @requests << request
      response = @responses.shift
      raise "Unexpected request" unless response
      block_given? ? yield(response) : response
    end
  end

  TOOLS = [{ type: "function", name: "lookup_order", description: "Look up shipping status",
             parameters: { type: "object", properties: { order_id: { type: "integer" } }, required: ["order_id"] } }].freeze

  def setup
    [AiLite::OpenAI, AiLite::Gemini].each(&:reset_configuration!)
  end

  def teardown
    [AiLite::OpenAI, AiLite::Gemini].each(&:reset_configuration!)
  end

  def with_http(*bodies)
    http = Http.new(bodies.map { |body| Response.new("200", body.is_a?(String) ? body : JSON.generate(body)) })
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*args, **kwargs, &block| block.call(http) }
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def call_for(provider, id = "call-1", args = { "order_id" => 123 })
    if provider == AiLite::OpenAI
      { "type" => "function_call", "id" => "item-#{id}", "call_id" => id, "name" => "lookup_order", "arguments" => JSON.generate(args) }
    else
      { "type" => "function_call", "id" => id, "name" => "lookup_order", "arguments" => args }
    end
  end

  def response_for(provider, calls = nil, status = nil)
    if provider == AiLite::OpenAI
      { "id" => "response-1", "status" => status || "completed", "output" => calls || [
        { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Shipped." }] }
      ] }
    else
      { "id" => "response-1", "status" => status || (calls ? "requires_action" : "completed"), "steps" => calls || [
        { "type" => "model_output", "content" => [{ "type" => "text", "text" => "Shipped." }] }
      ] }
    end
  end

  def test_two_turn_function_roundtrip_for_both_providers
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      provider.configure { |c| c.api_key = "key" }
      with_http(response_for(provider, [call_for(provider)]), response_for(provider)) do |http|
        first = provider.chat("Where is order 123?", tools: TOOLS)
        assert_nil first["error"]
        assert_nil first["content"]
        assert_nil first["raw"]
        assert_equal [{ "id" => "call-1", "name" => "lookup_order", "arguments" => { "order_id" => 123 } }], first["tool_calls"]
        assert_equal JSON.parse(JSON.generate(TOOLS)), JSON.parse(http.requests.first.body)["tools"]
        results = [{ id: first["tool_calls"][0]["id"], name: "lookup_order", output: { status: "shipped" } }]
        original = Marshal.dump(results)
        final = provider.chat(nil, tools: TOOLS, previous_response_id: first["response_id"], tool_results: results)
        assert_equal "Shipped.", final["content"]
        assert_nil final["error"]
        refute final.key?("tool_calls")
        assert_equal original, Marshal.dump(results)
        payload = JSON.parse(http.requests.last.body)
        item = payload["input"][0]
        assert_equal "call-1", item["call_id"]
        if provider == AiLite::OpenAI
          assert_equal "response-1", payload["previous_response_id"]
          assert_equal "function_call_output", item["type"]
          assert_equal '{"status":"shipped"}', item["output"]
        else
          assert_equal "response-1", payload["previous_interaction_id"]
          assert_equal "function_result", item["type"]
          assert_equal "lookup_order", item["name"]
          assert_equal [{ "type" => "text", "text" => '{"status":"shipped"}' }], item["result"]
        end
      end
    end
  end

  def test_parallel_calls_text_and_debug
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      raw = response_for(provider)
      raw[provider == AiLite::OpenAI ? "output" : "steps"].concat([call_for(provider), call_for(provider, "call-2", {})])
      with_http(raw) do
        result = provider.new(api_key: "key").chat("Check two orders", tools: TOOLS, debug: true)
        assert_nil result["error"]
        assert_equal "Shipped.", result["content"]
        assert_equal ["call-1", "call-2"], result["tool_calls"].map { |call| call["id"] }
        assert_equal raw, result["raw"]
      end
    end
  end

  def test_tool_option_precedence_and_no_mutation
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      options = { "tools" => TOOLS, temperature: 0.2 }
      original = Marshal.dump(options)
      with_http(response_for(provider), response_for(provider)) do |http|
        client = provider.new(api_key: "key")
        client.chat("Hi", options: options)
        assert_equal JSON.parse(JSON.generate(TOOLS)), JSON.parse(http.requests[0].body)["tools"]
        client.chat("Hi", options: options, tools: [])
        assert_equal [], JSON.parse(http.requests[1].body)["tools"]
      end
      assert_equal original, Marshal.dump(options)
    end
  end

  def test_invalid_results_and_tools_do_not_call_api
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      with_http do |http|
        client = provider.new(api_key: "key")
        [false, {}, [1]].each { |tools| refute_nil client.chat("Hi", tools: tools)["error"] }
        valid = { id: "call", name: "lookup_order", output: false }
        [[], {}, [1], [{ id: "call" }], [valid, valid]].each do |results|
          refute_nil client.chat(nil, previous_response_id: "response", tool_results: results)["error"]
        end
        refute_nil client.chat(nil, tool_results: [valid])["error"]
        refute_nil client.chat("Ambiguous input", previous_response_id: "response", tool_results: [valid])["error"]
        assert_empty http.requests
      end
    end
  end

  def test_failed_and_malformed_calls_are_not_executable
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      client = provider.new(api_key: "key")
      %w[failed incomplete cancelled].each do |status|
        with_http(response_for(provider, [call_for(provider)], status)) do
          result = client.chat("Hi", tools: TOOLS)
          refute_nil result["error"]
          refute result.key?("tool_calls")
        end
      end
      bad_calls = [call_for(provider).merge("arguments" => "{bad"), call_for(provider).merge("arguments" => "[]"),
                   call_for(provider).merge("name" => ""), call_for(provider).merge("call_id" => nil, "id" => nil)]
      bad_calls.each do |call|
        with_http(response_for(provider, [call])) do
          result = client.chat("Hi", tools: TOOLS)
          refute_nil result["error"]
          refute result.key?("tool_calls")
        end
      end
    end
  end

  def test_native_history_and_falsy_tool_results_are_preserved
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      client = provider.new(api_key: "key")
      input = provider == AiLite::OpenAI ? [{ type: "function_call_output", call_id: "call", output: "native" }] :
        [{ type: "function_result", name: "lookup_order", call_id: "call", result: [{ type: "text", text: "native" }] }]
      with_http(response_for(provider)) do |http|
        client.chat(input, tools: TOOLS, previous_response_id: "previous")
        assert_equal JSON.parse(JSON.generate(input)), JSON.parse(http.requests.first.body)["input"]
      end
      [false, nil, ""].each do |output|
        with_http(response_for(provider)) do |http|
          result = client.chat(nil, previous_response_id: "previous", tool_results: [{ id: "call", name: "lookup_order", output: output }])
          assert_nil result["error"]
          item = JSON.parse(http.requests.first.body)["input"][0]
          actual = provider == AiLite::OpenAI ? item["output"] : item.dig("result", 0, "text")
          assert_equal(output.is_a?(String) ? output : JSON.generate(output), actual)
        end
      end
    end
  end

  def test_incomplete_openai_calls_and_failed_streams_are_not_executable
    provider = AiLite::OpenAI
    client = provider.new(api_key: "key")
    [response_for(provider, [call_for(provider)], "in_progress"),
     response_for(provider, [call_for(provider).merge("status" => "in_progress")])].each do |raw|
      with_http(raw) do
        result = client.chat("Hi", tools: TOOLS, debug: true)
        refute_nil result["error"]
        refute result.key?("tool_calls")
        assert_equal raw, result["raw"]
      end
    end
    [AiLite::OpenAI, AiLite::Gemini].each do |klass|
      raw = response_for(klass, [call_for(klass)], "failed")
      raw["error"] = { "message" => "Failed" }
      stream = sse(klass, klass == AiLite::OpenAI ? "response.completed" : "interaction.completed",
                   { (klass == AiLite::OpenAI ? "response" : "interaction") => raw })
      with_http(stream) do
        result = klass.new(api_key: "key").chat_stream("Hi", tools: TOOLS) { |_| }
        refute_nil result["error"]
        refute result.key?("tool_calls")
      end
    end
  end

  def sse(provider, type, fields)
    "data: #{JSON.generate(fields.merge(provider == AiLite::OpenAI ? 'type' : 'event_type' => type))}\n\n"
  end

  def test_openai_stream_returns_complete_calls_without_yielding_arguments
    provider = AiLite::OpenAI
    raw = response_for(provider, [call_for(provider)])
    stream = sse(provider, "response.function_call_arguments.delta", { "delta" => '{"order_id":123}' }) +
             sse(provider, "response.completed", { "response" => raw })
    with_http(stream) do |http|
      result = provider.new(api_key: "key").chat_stream("Check order", tools: TOOLS) { flunk "Arguments must not be yielded" }
      assert_nil result["error"]
      assert_equal "call-1", result["tool_calls"][0]["id"]
      assert_equal JSON.parse(JSON.generate(TOOLS)), JSON.parse(http.requests.first.body)["tools"]
    end
  end

  def gemini_call_stream(tail = nil)
    provider = AiLite::Gemini
    sse(provider, "interaction.created", { "interaction" => { "id" => "response-1", "status" => "in_progress" } }) +
      sse(provider, "step.start", { "index" => 1, "step" => call_for(provider).merge("arguments" => {}) }) +
      sse(provider, "step.delta", { "index" => 1, "delta" => { "type" => "arguments_delta", "arguments" => '{"order_' } }) +
      sse(provider, "step.delta", { "index" => 1, "delta" => { "type" => "arguments_delta", "arguments" => 'id":123}' } }) +
      sse(provider, "step.stop", { "index" => 1 }) +
      (tail || sse(provider, "interaction.status_update", { "interaction_id" => "response-1", "status" => "requires_action" }))
  end

  def test_gemini_stream_assembles_fragments_and_handles_action_status
    provider = AiLite::Gemini
    [nil, sse(provider, "interaction.completed", { "interaction" => { "id" => "response-1", "status" => "requires_action" } }),
     sse(provider, "interaction.completed", { "interaction" => response_for(provider, [call_for(provider)]) })].each do |tail|
      with_http(gemini_call_stream(tail)) do
        result = provider.new(api_key: "key").chat_stream("Check order", tools: TOOLS) { flunk "Arguments must not be yielded" }
        assert_nil result["error"]
        assert_equal "response-1", result["response_id"]
        assert_equal [{ "id" => "call-1", "name" => "lookup_order", "arguments" => { "order_id" => 123 } }], result["tool_calls"]
      end
    end
    with_http(gemini_call_stream.sub(sse(provider, "step.stop", { "index" => 1 }), "")) do
      result = provider.new(api_key: "key").chat_stream("Check order", tools: TOOLS) { |_| }
      refute_nil result["error"]
      refute result.key?("tool_calls")
    end
  end

  def test_stream_tool_results_class_delegation
    [AiLite::OpenAI, AiLite::Gemini].each do |provider|
      provider.configure { |c| c.api_key = "key" }
      raw = response_for(provider, [])
      raw["status"] = "completed"
      stream = sse(provider, provider == AiLite::OpenAI ? "response.completed" : "interaction.completed",
                   { (provider == AiLite::OpenAI ? "response" : "interaction") => raw })
      with_http(stream) do |http|
        result = provider.chat_stream(nil, previous_response_id: "previous", tools: TOOLS,
          tool_results: [{ "id" => "call-1", "name" => "lookup_order", "output" => "Shipped" }]) { |_| }
        assert_nil result["error"]
        assert_equal "call-1", JSON.parse(http.requests.first.body).dig("input", 0, "call_id")
      end
    end
  end
end
