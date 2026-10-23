class AiLite
  class Gemini
    API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta".freeze
    DEFAULT_MODEL = "gemini-3.8-flash".freeze
    DEFAULT_EMBEDDING_MODEL = "gemini-embedding-001".freeze
    DEFAULT_IMAGE_MODEL = "gemini-nano-banana-2.1".freeze
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_OUTPUT_TOKENS = 2000

    class Configuration
      attr_accessor :api_key, :model, :embedding_model, :image_model, :timeout, :max_output_tokens

      def initialize
        @api_key = nil
        @model = DEFAULT_MODEL
        @embedding_model = DEFAULT_EMBEDDING_MODEL
        @image_model = DEFAULT_IMAGE_MODEL
        @timeout = DEFAULT_TIMEOUT
        @max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS
      end
    end
  end
end
