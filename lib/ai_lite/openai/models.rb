class AiLite
  class OpenAI
    module Models
      def self.configuration_snapshot(source)
        {
          "chat" => source.model,
          "moderation" => source.moderation_model,
          "embedding" => source.embedding_model,
          "image" => source.image_model,
          "speech" => source.speech_model,
          "transcription" => source.transcription_model
        }.transform_values { |value| value.is_a?(String) ? value.dup : value }
      end

      def configured_models
        Models.configuration_snapshot(self)
      end

      def available_models(debug: false)
        response = nil
        raw = nil
        uri = URI.parse("#{API_BASE_URL}/models")
        request = Net::HTTP::Get.new(uri)
        headers.each { |key, value| request[key] = value }
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.request(request)
        end
        raw = response.body
        raw = JSON.parse(raw)
        unless success_status?(response.code.to_i)
          return prettify_data(status: response.code.to_i, error: error_message(raw), raw: raw, debug: debug)
        end

        unless raw.is_a?(Hash) && raw["data"].is_a?(Array) && raw["data"].all? { |item|
          item.is_a?(Hash) && item["id"].is_a?(String) && !item["id"].empty?
        }
          raise "Invalid model list response"
        end

        prettify_data(status: response.code.to_i, content: raw["data"].map { |item| item["id"] }.uniq,
                      raw: raw, debug: debug)
      rescue StandardError => e
        prettify_data(status: response_status(response), error: e.message, raw: raw, debug: debug)
      end

      # nil means the lookup failed; false means a successful lookup did not find it.
      def model_available?(model_id)
        unless model_id.is_a?(String) && !model_id.strip.empty?
          raise ArgumentError, "model_id must be a nonempty string"
        end

        result = available_models
        return nil if result["error"]

        result["content"].include?(model_id)
      end

      def check_configured_models(debug: false)
        configured = configured_models
        result = available_models(debug: debug)
        report = configured.each_with_object({}) do |(usage, model), entries|
          entries[usage] = {
            "model" => model,
            "usage" => usage,
            "available" => result["error"] ? nil : result["content"].include?(model),
            "error" => result["error"]
          }
        end
        result.merge("content" => report)
      end
    end

    include Models
    private_constant :Models

    class << self
      def configured_models
        Models.configuration_snapshot(configuration)
      end

      def available_models(**kwargs)
        client.available_models(**kwargs)
      end

      def model_available?(model_id)
        client.model_available?(model_id)
      end

      def check_configured_models(**kwargs)
        client.check_configured_models(**kwargs)
      end
    end
  end
end
