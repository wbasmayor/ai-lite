class AiLite
  class OpenAI
    API_BASE_URL = "https://api.openai.com/v1".freeze
    DEFAULT_MODEL = "gpt-5.5".freeze
    DEFAULT_MODERATION_MODEL = "omni-moderation-latest".freeze
    DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small".freeze
    DEFAULT_IMAGE_MODEL = "gpt-image-2".freeze
    DEFAULT_SPEECH_MODEL = "gpt-4o-mini-tts".freeze
    DEFAULT_SPEECH_VOICE = "alloy".freeze
    DEFAULT_SPEECH_FORMAT = "mp3".freeze
    DEFAULT_TRANSCRIPTION_MODEL = "gpt-transcribe".freeze
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_OUTPUT_TOKENS = 2000
    IMAGE_MIME_TYPES = {
      ".gif" => "image/gif",
      ".jpeg" => "image/jpeg",
      ".jpg" => "image/jpeg",
      ".png" => "image/png",
      ".webp" => "image/webp"
    }.freeze
    AUDIO_MIME_TYPES = {
      ".flac" => "audio/flac",
      ".m4a" => "audio/mp4",
      ".mp3" => "audio/mpeg",
      ".mp4" => "audio/mp4",
      ".mpeg" => "audio/mpeg",
      ".mpga" => "audio/mpeg",
      ".ogg" => "audio/ogg",
      ".wav" => "audio/wav",
      ".webm" => "audio/webm"
    }.freeze

    class Configuration
      attr_accessor :api_key, :model, :moderation_model, :embedding_model, :image_model, :speech_model, :speech_voice, :transcription_model, :timeout, :max_output_tokens

      def initialize
        @api_key = nil
        @model = DEFAULT_MODEL
        @moderation_model = DEFAULT_MODERATION_MODEL
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
