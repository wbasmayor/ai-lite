class AiLite
  class Gemini
    module Transcription
      MIME_TYPES = {
        ".wav" => "audio/wav", ".mp3" => "audio/mp3", ".aiff" => "audio/aiff",
        ".aif" => "audio/aiff", ".aac" => "audio/aac", ".ogg" => "audio/ogg",
        ".flac" => "audio/flac", ".mpeg" => "audio/mpeg", ".m4a" => "audio/m4a",
        ".l16" => "audio/l16", ".pcm" => "audio/l16", ".opus" => "audio/opus",
        ".alaw" => "audio/alaw", ".mulaw" => "audio/mulaw", ".webm" => "audio/webm"
      }.freeze
      MAX_REQUEST_BYTES = 20_000_000

      def transcribe(file_path, model: nil, mime_type: nil, debug: false, options: {})
        response = raw = response_id = nil
        raise ArgumentError, "options must be a hash" unless options.is_a?(Hash)

        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        raise ArgumentError, "Streaming and background transcription are not supported" if payload["stream"] || payload["background"]
        unless file_path.is_a?(String) && File.file?(file_path)
          raise ArgumentError, "file_path must point to an existing audio file"
        end
        mime = mime_type || MIME_TYPES[File.extname(file_path).downcase]
        unless mime.is_a?(String) && MIME_TYPES.value?(mime.split(";", 2).first)
          raise ArgumentError, "Unsupported audio format; supply a supported mime_type"
        end
        # Bound the read before allocating the base64 request, even if the file grows.
        audio = File.binread(file_path, MAX_REQUEST_BYTES * 3 / 4)
        raise ArgumentError, "Audio file is empty" if audio.empty?

        payload.merge!("model" => model || transcription_model,
                       "input" => [{ "type" => "audio", "data" => [audio].pack("m0"), "mime_type" => mime }])
        if JSON.generate(payload).bytesize >= MAX_REQUEST_BYTES
          raise ArgumentError, "Inline transcription request must be under 20 MB; use a smaller audio file"
        end
        response = post_interaction(payload)
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Gemini response: expected an object" unless raw.is_a?(Hash)

        response_id = raw["id"]
        unless response.code.to_i.between?(200, 299) && !raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw),
                                 response_id: response_id, raw: raw, debug: debug)
        end
        raise "Gemini interaction #{raw['status'] || 'has no status'}" unless raw["status"] == "completed"
        raise "Invalid Gemini response: expected steps" unless raw["steps"].is_a?(Array)

        parts = raw["steps"].flat_map do |step|
          next [] unless step.is_a?(Hash) && step["type"] == "model_output" && step["content"].is_a?(Array)

          step["content"].select { |part| part.is_a?(Hash) && part["type"] == "text" && part["text"].is_a?(String) }
        end
        raise "Gemini response did not include transcript text" if parts.empty?

        result_envelope(status: response.code.to_i, content: parts.map { |part| part["text"] }.join,
                        response_id: response_id, raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message,
                        response_id: response_id, raw: raw, debug: debug)
      end
    end

    include Transcription
    private_constant :Transcription
  end
end
