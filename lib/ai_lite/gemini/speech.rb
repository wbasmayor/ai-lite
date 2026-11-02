class AiLite
  class Gemini
    module Speech
      FORMATS = { "wav" => "audio/wav", "pcm" => "audio/l16",
                  "mulaw" => "audio/mulaw", "alaw" => "audio/alaw" }.freeze

      def speak(text, model: nil, voice: nil, instructions: nil, response_format: nil,
                output_path: nil, base64: false, debug: false, options: {})
        response = nil
        raw = nil
        response_id = nil
        unless text.is_a?(String) && !text.strip.empty?
          raise ArgumentError, "text must be a nonempty string"
        end
        unless instructions.nil? || instructions.is_a?(String)
          raise ArgumentError, "instructions must be a string"
        end
        if response_format && !FORMATS.key?(response_format)
          raise ArgumentError, "response_format must be wav, pcm, mulaw, or alaw"
        end
        selected_voice = voice || speech_voice
        unless selected_voice.is_a?(String) && !selected_voice.strip.empty?
          raise ArgumentError, "voice must be a nonempty string"
        end
        payload = speech_hash(options, "options")
        if payload["stream"] || payload["background"]
          raise ArgumentError, "speak does not support streaming or background execution"
        end
        generation = speech_hash(payload.fetch("generation_config", {}), "generation_config")
        # The helper deliberately owns single-speaker voice selection.
        generation["speech_config"] = [{ "voice" => selected_voice }]
        format = speech_hash(payload.fetch("response_format", {}), "response_format option")
        format["type"] = "audio"
        format["mime_type"] = FORMATS.fetch(response_format) if response_format
        format["mime_type"] ||= FORMATS.fetch("wav")
        unless FORMATS.value?(format["mime_type"])
          raise ArgumentError, "Unsupported speech MIME type"
        end
        part = { "type" => "text", "text" => text }
        part["annotations"] = [{ "type" => "speech_metadata", "style" => instructions }] if instructions
        payload.merge!("model" => model || speech_model,
                       "input" => [{ "type" => "user_input", "content" => [part] }],
                       "response_format" => format, "generation_config" => generation)
        response = post_interaction(payload)
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Gemini speech response: expected an object" unless raw.is_a?(Hash)

        response_id = raw["id"]
        if !response.code.to_i.between?(200, 299) || raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw),
                                 response_id: response_id, raw: raw, debug: debug)
        end
        unless raw["status"] == "completed"
          raise "Gemini interaction #{raw['status'] || 'has no status'}; inspect raw with debug: true"
        end
        raise "Invalid Gemini speech response: expected steps" unless raw["steps"].is_a?(Array)

        blocks = raw["steps"].flat_map do |step|
          next [] unless step.is_a?(Hash) && step["type"] == "model_output"

          step["content"].is_a?(Array) ? step["content"] : []
        end.select { |block| block.is_a?(Hash) && block["type"] == "audio" }
        # Joining WAV containers or silently dropping speech would corrupt the result.
        raise "Expected one audio block; inspect raw with debug: true" unless blocks.length == 1

        block = blocks.first
        encoded = block["data"]
        unless encoded.is_a?(String) && !encoded.empty?
          raise "No inline audio data returned; inspect raw with debug: true"
        end
        mime = block["mime_type"].to_s.split(";").first.to_s.strip.downcase
        actual_format = FORMATS.key(mime)
        raise "Unsupported or missing audio MIME type: #{mime}" unless actual_format

        audio = encoded.unpack1("m0")
        raise "Empty audio data returned" if audio.empty?
        if actual_format == "wav" && !(audio.bytesize >= 12 && audio.start_with?("RIFF") && audio.byteslice(8, 4) == "WAVE")
          raise "Invalid WAV audio returned"
        end
        File.binwrite(output_path, audio) if output_path
        content = if base64
                    [audio].pack("m0")
                  elsif output_path
                    { "path" => output_path, "bytes" => audio.bytesize, "format" => actual_format }
                  else
                    audio
                  end
        result_envelope(status: response.code.to_i, content: content, response_id: response_id,
                        raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message,
                        response_id: response_id, raw: raw, debug: debug)
      end

      private

      def speech_hash(value, name)
        raise ArgumentError, "#{name} must be a hash" unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
    end

    include Speech
    private_constant :Speech
  end
end
