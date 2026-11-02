class AiLite
  class Gemini
    API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta".freeze
    DEFAULT_MODEL = "gemini-3.8-flash".freeze
    DEFAULT_EMBEDDING_MODEL = "gemini-embedding-001".freeze
    DEFAULT_IMAGE_MODEL = "gemini-nano-banana-2.1".freeze
    DEFAULT_SPEECH_MODEL = "gemini-3.8-flash-tts".freeze
    DEFAULT_SPEECH_VOICE = "Kore".freeze
    DEFAULT_TRANSCRIPTION_MODEL = "gemini-3.5-transcribe".freeze
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_OUTPUT_TOKENS = 2000

    class Configuration
      attr_accessor :api_key, :model, :embedding_model, :image_model, :speech_model, :speech_voice, :transcription_model, :timeout, :max_output_tokens

      def initialize
        @api_key = nil
        @model = DEFAULT_MODEL
        @embedding_model = DEFAULT_EMBEDDING_MODEL
        @image_model = DEFAULT_IMAGE_MODEL
        @speech_model = DEFAULT_SPEECH_MODEL
        @speech_voice = DEFAULT_SPEECH_VOICE
        @transcription_model = DEFAULT_TRANSCRIPTION_MODEL
        @timeout = DEFAULT_TIMEOUT
        @max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS
      end
    end
  end
end
