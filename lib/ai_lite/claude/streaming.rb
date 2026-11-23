class AiLite
  class Claude
    module Streaming
      def chat_stream(message, model: nil, instructions: nil, previous_response_id: nil, max_output_tokens: nil, tools: nil, tool_results: nil, debug: false, options: {}, &block)
        raise ArgumentError, "chat_stream requires a block" unless block

        status = "unknown"
        text = +""
        raw = response_id = callback_error = nil
        begin
          payload = chat_payload(message, model: model, instructions: instructions,
            previous_response_id: previous_response_id, max_output_tokens: max_output_tokens,
            options: options, stream: true, tools: tools, tool_results: tool_results)
          uri = URI.parse("#{API_BASE_URL}/messages")
          request = Net::HTTP::Post.new(uri)
          headers.each { |key, value| request[key] = value }
          request["Accept"] = "text/event-stream"
          request.body = JSON.generate(payload)
          active = {}
          fragments = {}
          result = nil
          Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
            http.open_timeout = timeout
            http.read_timeout = timeout
            catch(:ai_lite_claude_finished) do
              http.request(request) do |response|
                status = response.code.to_i
                unless status.between?(200, 299)
                  raw = +""
                  response.read_body { |chunk| raw << chunk }
                  raw = JSON.parse(raw)
                  raise error_message(raw)
                end
                each_claude_stream_event(response) do |event|
                  case event["type"]
                  when "message_start"
                    raise "Duplicate message_start" if raw
                    raw = event.fetch("message")
                    unless raw.is_a?(Hash) && raw["type"] == "message" && raw["role"] == "assistant" && raw["content"] == []
                      raise "Invalid Claude streaming message"
                    end
                    response_id = raw["id"]
                  when "content_block_start"
                    raise "Missing message_start" unless raw
                    index = event.fetch("index")
                    raise "Invalid content block index" unless index == raw["content"].length
                    part = event.fetch("content_block")
                    raise "Invalid content block" unless part.is_a?(Hash)
                    raw["content"] << part
                    active[index] = part
                  when "content_block_delta"
                    part = active.fetch(event.fetch("index"))
                    delta = event.fetch("delta")
                    case delta["type"]
                    when "text_delta", "thinking_delta", "signature_delta"
                      field = delta["type"].sub(/_delta\z/, "")
                      expected = field == "text" ? "text" : "thinking"
                      raise "Invalid #{field} delta" unless part["type"] == expected && delta[field].is_a?(String)
                      part[field] = (part[field] || "") + delta[field]
                      if field == "text"
                        text << delta[field]
                        begin
                          block.call(delta[field])
                        rescue StandardError => e
                          callback_error = e
                          raise
                        end
                      end
                    when "input_json_delta"
                      raise "Invalid tool input delta" unless %w[tool_use server_tool_use].include?(part["type"])
                      index = event["index"]
                      fragments[index] ||= +""
                      fragments[index] << delta.fetch("partial_json")
                    when "citations_delta"
                      (part["citations"] ||= []) << delta.fetch("citation")
                    end
                  when "content_block_stop"
                    index = event.fetch("index")
                    part = active.fetch(index)
                    part["input"] = JSON.parse(fragments.delete(index)) if fragments.key?(index)
                    active.delete(index)
                  when "message_delta"
                    raise "Missing message_start" unless raw
                    raw.merge!(event.fetch("delta"))
                    raw["usage"] = (raw["usage"] || {}).merge(event["usage"] || {})
                  when "message_stop"
                    raise "Incomplete Claude streaming message" unless raw && active.empty?
                    result = chat_result(raw, status: status, debug: debug)
                    throw :ai_lite_claude_finished
                  when "error"
                    raw = event
                    raise error_message(event)
                  end
                end
              end
            end
          end
          result || result_envelope(status: status, content: text.empty? ? nil : text,
            response_id: response_id, error: "Stream ended before message_stop", raw: raw, debug: debug)
        rescue StandardError => e
          raise if callback_error.equal?(e)

          result_envelope(status: status, content: text.empty? ? nil : text,
            response_id: response_id, error: e.message, raw: raw, debug: debug)
        end
      end

      private
      def each_claude_stream_event(response)
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
