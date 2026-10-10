require "json"
require "net/http"
require "uri"
require_relative "version"
require_relative "gemini/configuration"
require_relative "gemini/chat"
require_relative "gemini/streaming"
require_relative "gemini/youtube"
require_relative "gemini/models"

class AiLite
  class Gemini
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
        reset_client!
        configuration
      end

      def reset_configuration!
        @configuration = Configuration.new
        reset_client!
        configuration
      end

      def client
        @client ||= new
      end

      def reset_client!
        @client = nil
      end

      def youtube(url, prompt:, **kwargs)
        client.youtube(url, prompt: prompt, **kwargs)
      end

      def chat_stream(message, **kwargs, &block)
        client.chat_stream(message, **kwargs, &block)
      end

      def chat(message, **kwargs)
        client.chat(message, **kwargs)
      end
    end

    attr_reader :api_key, :model, :timeout, :max_output_tokens, :headers

    def initialize(api_key: nil, model: nil, timeout: nil, max_output_tokens: nil)
      config = self.class.configuration
      @api_key = api_key || config.api_key || ENV["GEMINI_API_KEY"]
      raise ArgumentError, "Missing Gemini API key" if @api_key.to_s.strip.empty?

      @model = model || config.model
      @timeout = timeout || config.timeout
      @max_output_tokens = max_output_tokens || config.max_output_tokens
      @headers = { "x-goog-api-key" => @api_key, "Content-Type" => "application/json" }
    end

    private

    def post_interaction(payload)
      uri = URI.parse("#{API_BASE_URL}/interactions")
      request = Net::HTTP::Post.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = JSON.generate(payload)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.request(request)
      end
    end

    def result_envelope(status:, content: nil, error: nil, response_id: nil, raw: nil, debug: false)
      {
        "content" => content, "response_id" => response_id, "status" => status,
        "error" => error, "raw" => debug ? raw : nil
      }
    end

    def error_message(raw)
      return raw.to_s unless raw.is_a?(Hash)

      error = raw["error"]
      error.is_a?(Hash) ? (error["message"] || error["status"] || error.to_s) : (error || raw["message"] || raw.to_s)
    end
  end
end
