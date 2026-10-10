class AiLite
  class OpenAI
    module Streaming
      # Text deltas are yielded immediately; the return value is the final envelope.
      def chat_stream(message, model: nil, instructions: nil, previous_response_id: nil, max_output_tokens: nil, debug: false, options: {}, &block)
        raise ArgumentError, "chat_stream requires a block" unless block

        status = "unknown"
        text = +""
        response_id = nil
        raw = nil
        callback_error = nil
        begin
          payload = options.reject { |key, _| key.to_s == "stream" }.merge(
            model: model || self.model, input: message, stream: true,
            max_output_tokens: max_output_tokens || self.max_output_tokens
          )
          payload[:instructions] = instructions if instructions
          payload[:previous_response_id] = previous_response_id if previous_response_id
          uri = URI.parse(response_endpoint)
          request = Net::HTTP::Post.new(uri)
          headers.each { |key, value| request[key] = value }
          request["Accept"] = "text/event-stream"
          request.body = JSON.generate(payload)
          result = nil

          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.open_timeout = timeout
            http.read_timeout = timeout
            # Exit the request block at the terminal event, closing the connection.
            catch(:ai_lite_stream_finished) do
              http.request(request) do |response|
                status = response.code.to_i
                unless success_status?(status)
                  body = +""
                  response.read_body { |chunk| body << chunk }
                  raw = body
                  raw = JSON.parse(body)
                  result = prettify_data(status: status, error: error_message(raw), raw: raw, debug: debug)
                  throw :ai_lite_stream_finished
                end

                each_stream_event(response) do |event|
                  raw = event
                  response_id = event.dig("response", "id") || response_id
                  case event["type"]
                  when "response.output_text.delta"
                    delta = event.fetch("delta")
                    text << delta
                    begin
                      block.call(delta)
                    rescue StandardError => e
                      callback_error = e
                      raise
                    end
                  when "response.completed", "response.failed", "response.incomplete"
                    raw = event.fetch("response")
                    error = case event["type"]
                            when "response.failed"
                              raw["error"] ? error_message(raw) : "Response failed"
                            when "response.incomplete"
                              "Response incomplete: #{raw.dig('incomplete_details', 'reason') || 'unknown reason'}"
                            end
                    content = error ? text : parse_content(extract_output_text(raw))
                    result = prettify_data(status: status, content: content, error: error,
                                           response_id: response_id, raw: raw, debug: debug)
                    throw :ai_lite_stream_finished
                  when "error"
                    result = prettify_data(status: status, content: text, error: error_message(event),
                                           response_id: response_id, raw: raw, debug: debug)
                    throw :ai_lite_stream_finished
                  end
                end
              end
            end
          end
          result || prettify_data(status: status, content: text, response_id: response_id,
                                  error: "Stream ended before a terminal response event", raw: raw, debug: debug)
        rescue StandardError => e
          raise if callback_error.equal?(e)

          prettify_data(status: status, content: text.empty? ? nil : text, response_id: response_id,
                        error: e.message, raw: raw, debug: debug)
        end
      end

      private

      def each_stream_event(response)
        buffer = +"".b
        data = []
        consume = lambda do
          while (boundary = buffer.index(/[\r\n]/))
            # A trailing CR might be the first byte of a CRLF split across reads.
            break if buffer.getbyte(boundary) == 13 && boundary == buffer.bytesize - 1

            width = buffer.byteslice(boundary, 2) == "\r\n" ? 2 : 1
            line = buffer.slice!(0, boundary + width).byteslice(0, boundary)
            if line.empty?
              unless data.empty?
                payload = data.join("\n").force_encoding(Encoding::UTF_8)
                data.clear
                unless payload == "[DONE]"
                  event = JSON.parse(payload)
                  raise "Invalid streaming event: expected an object" unless event.is_a?(Hash)
                  yield event
                end
              end
            elsif line.start_with?("data:")
              data << line.sub(/\Adata: ?/, "")
            end
          end
        end
        response.read_body do |chunk|
          buffer << chunk.b
          consume.call
        end
        # A final lone CR is a complete line delimiter at EOF.
        if buffer.end_with?("\r")
          buffer << "\n"
          consume.call
        end
      end

    end

    include Streaming
    private_constant :Streaming
  end
end
