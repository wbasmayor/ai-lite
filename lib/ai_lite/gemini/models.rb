class AiLite
  class Gemini
    module Models
      def self.snapshot(source)
        { "chat" => source.model.is_a?(String) ? source.model.dup : source.model }
      end

      def configured_models
        Models.snapshot(self)
      end

      def available_models(debug: false)
        status = "unknown"
        pages = []
        ids = []
        tokens = []
        token = nil
        loop do
          status = "unknown"
          uri = URI.parse("#{API_BASE_URL}/models")
          uri.query = URI.encode_www_form(pageToken: token) if token
          request = Net::HTTP::Get.new(uri)
          headers.each { |key, value| request[key] = value }
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.open_timeout = timeout
            http.read_timeout = timeout
            http.request(request)
          end
          status = response.code.to_i
          pages << response.body if debug
          page = JSON.parse(response.body)
          pages[-1] = page if debug
          if !status.between?(200, 299) || (page.is_a?(Hash) && page["error"])
            return result_envelope(status: status, error: error_message(page), raw: { "pages" => pages }, debug: debug)
          end
          # Protobuf JSON may omit an empty repeated field (models).
          unless page.is_a?(Hash) && page.fetch("models", []).is_a?(Array)
            raise "Invalid Gemini model list response"
          end
          page.fetch("models", []).each do |entry|
            unless entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["name"].match?(%r{\Amodels/[^/\s]+\z})
              raise "Invalid Gemini model record"
            end
            ids << entry["name"].delete_prefix("models/")
          end
          token = page["nextPageToken"]
          break if token.nil? || token == ""
          raise "Invalid Gemini pagination token" unless token.is_a?(String)
          raise "Repeated Gemini pagination token" if tokens.include?(token)
          tokens << token
        end
        result_envelope(status: status, content: ids.uniq, raw: { "pages" => pages }, debug: debug)
      rescue StandardError => e
        result_envelope(status: status, error: e.message, raw: { "pages" => pages }, debug: debug)
      end

      def model_available?(model_id)
        unless model_id.is_a?(String) && !model_id.strip.empty?
          raise ArgumentError, "model_id must be a nonempty string"
        end
        result = available_models
        return nil if result["error"]

        result["content"].include?(model_id.delete_prefix("models/"))
      end

      def check_configured_models(debug: false)
        configured = configured_models
        result = available_models(debug: debug)
        report = configured.each_with_object({}) do |(usage, model), entries|
          entries[usage] = {
            "model" => model, "usage" => usage,
            "available" => result["error"] ? nil : result["content"].include?(model.to_s.delete_prefix("models/")),
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
        Models.snapshot(configuration)
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
