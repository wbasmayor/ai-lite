class AiLite
  class Claude
    API_BASE_URL = "https://api.anthropic.com/v1".freeze
    DEFAULT_MODEL = "claude-haiku-5-5".freeze
    DEFAULT_API_VERSION = "2026-10-21".freeze
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_OUTPUT_TOKENS = 2000

    class Configuration
      attr_accessor :api_key, :model, :api_version, :workspace_id, :timeout, :max_output_tokens

      def initialize
        @api_key = nil
        @model = DEFAULT_MODEL
        @api_version = DEFAULT_API_VERSION
        @workspace_id = nil
        @timeout = DEFAULT_TIMEOUT
        @max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS
      end
    end
  end
end
