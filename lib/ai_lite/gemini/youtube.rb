class AiLite
  class Gemini
    module YouTube
      def youtube(url, prompt:, **kwargs)
        unless prompt.is_a?(String) && !prompt.strip.empty?
          raise ArgumentError, "prompt must be a nonempty string"
        end
        uri = URI.parse(url) if url.is_a?(String)
        unless uri.is_a?(URI::HTTPS) && !uri.userinfo && uri.port == 443
          raise ArgumentError, "Expected an HTTPS YouTube video URL"
        end
        video_id = case uri.host&.downcase
                   when "youtu.be"
                     uri.path.delete_prefix("/")
                   when "youtube.com", "www.youtube.com", "m.youtube.com"
                     if uri.path == "/watch"
                       ids = URI.decode_www_form(uri.query.to_s).select { |key, _| key == "v" }
                       ids.first[1] if ids.length == 1
                     else
                       uri.path.match(%r{\A/(?:shorts|embed|live)/([^/]+)\z})&.captures&.first
                     end
                   end
        unless video_id && video_id.match?(/\A[A-Za-z0-9_-]{11}\z/)
          raise ArgumentError, "Expected a YouTube video URL with a valid video ID"
        end

        chat([{ type: "video", uri: url }, { type: "text", text: prompt }], **kwargs)
      rescue ArgumentError, URI::InvalidURIError => e
        result_envelope(status: "unknown", error: e.message, debug: kwargs[:debug])
      end
    end

    include YouTube
    private_constant :YouTube
  end
end
