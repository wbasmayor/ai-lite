class AiLite
  class Gemini
    API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta".freeze
    DEFAULT_MODEL = "gemini-3.8-flash".freeze
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_OUTPUT_TOKENS = 2000

    class Configuration
      attr_accessor :api_key, :model, :timeout, :max_output_tokens

      def initialize
        @api_key = nil
        @model = DEFAULT_MODEL
        @timeout = DEFAULT_TIMEOUT
        @max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS
      end
    end
  end
end
