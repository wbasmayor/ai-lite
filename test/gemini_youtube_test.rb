require_relative "gemini_test"

class GeminiYouTubeTest < GeminiTest
  def test_youtube_builds_video_input_and_forwards_chat_options
    url = "https://www.youtube.com/watch?v=DV69qh0BzoA"
    with_http do |http|
      result = @client.youtube(url, prompt: "Summarize this video", model: "custom",
        instructions: "Be brief", previous_response_id: "previous", max_output_tokens: 100,
        debug: true, options: { store: false })
      payload = JSON.parse(http.request_received.body)
      assert_equal [{ "type" => "video", "uri" => url }, { "type" => "text", "text" => "Summarize this video" }], payload["input"]
      assert_equal "custom", payload["model"]
      assert_equal "Be brief", payload["system_instruction"]
      assert_equal "previous", payload["previous_interaction_id"]
      assert_equal 100, payload.dig("generation_config", "max_output_tokens")
      assert_equal false, payload["store"]
      assert_equal "Hello", result["content"]
      refute_nil result["raw"]
    end
  end

  def test_supported_url_forms_and_class_method
    AiLite::Gemini.configure { |c| c.api_key = "test-key" }
    %w[https://youtu.be/DV69qh0BzoA?t=10 https://m.youtube.com/watch?v=DV69qh0BzoA https://youtube.com/shorts/DV69qh0BzoA https://www.youtube.com/embed/DV69qh0BzoA https://youtube.com/live/DV69qh0BzoA].each do |url|
      with_http do
        assert_nil AiLite::Gemini.youtube(url, prompt: "Summarize")["error"]
      end
    end
  end

  def test_rejects_invalid_urls_and_prompts_before_network
    [nil, "garbage", "http://youtube.com/watch?v=DV69qh0BzoA", "https://youtube.com.evil.test/watch?v=DV69qh0BzoA",
     "https://user@youtube.com/watch?v=DV69qh0BzoA", "https://youtube.com/watch?v=short",
     "https://youtube.com/playlist?list=DV69qh0BzoA", "https://youtu.be/DV69qh0BzoA/extra",
     "https://youtube.com/watch?v=DV69qh0BzoA&v=DV69qh0BzoA"].each do |url|
      with_http do |http|
        refute_nil @client.youtube(url, prompt: "Summarize")["error"]
        assert_nil http.request_received
      end
    end
    [nil, "", " "].each do |prompt|
      with_http do |http|
        refute_nil @client.youtube("https://youtu.be/DV69qh0BzoA", prompt: prompt)["error"]
        assert_nil http.request_received
      end
    end
  end

  def test_provider_errors_are_preserved
    with_http({ "error" => { "message" => "Video unavailable" } }, "400") do
      result = @client.youtube("https://youtu.be/DV69qh0BzoA", prompt: "Summarize", debug: true)
      assert_equal 400, result["status"]
      assert_equal "Video unavailable", result["error"]
      refute_nil result["raw"]
    end
  end
end
