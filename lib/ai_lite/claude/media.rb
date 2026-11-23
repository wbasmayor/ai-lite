class AiLite
  class Claude
    module Media
      def image_input(path: nil, url: nil)
        { "type" => "image", "source" => media_source(path, url, {
          ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png",
          ".gif" => "image/gif", ".webp" => "image/webp"
        }) }
      end

      def pdf_input(path: nil, url: nil, title: nil, citations: nil)
        raise ArgumentError, "title must be a string" unless title.nil? || title.is_a?(String)
        unless citations.nil? || citations == true || citations == false
          raise ArgumentError, "citations must be true or false"
        end
        block = { "type" => "document", "source" => media_source(path, url, { ".pdf" => "application/pdf" }) }
        block["title"] = title.dup unless title.nil?
        block["citations"] = { "enabled" => citations } unless citations.nil?
        block
      end

      private

      def media_source(path, url, types)
        unless path.nil? != url.nil?
          raise ArgumentError, "Provide exactly one of path or url"
        end
        unless url.nil?
          unless url.is_a?(String) && !url.strip.empty?
            raise ArgumentError, "url must be an HTTP or HTTPS URL"
          end
          uri = URI.parse(url)
          unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? && !uri.userinfo
            raise ArgumentError, "url must be an HTTP or HTTPS URL without credentials"
          end
          return { "type" => "url", "url" => url.dup }
        end
        path = path.to_path if path.respond_to?(:to_path)
        unless path.is_a?(String) && !path.strip.empty?
          raise ArgumentError, "path must be a nonempty file path"
        end
        media_type = types[File.extname(path).downcase]
        raise ArgumentError, "Unsupported file extension; expected #{types.keys.join(', ')}" unless media_type
        raise ArgumentError, "path must refer to a regular file" unless File.file?(path)
        data = File.binread(path)
        raise ArgumentError, "File must not be empty" if data.empty?
        { "type" => "base64", "media_type" => media_type, "data" => [data].pack("m0") }
      rescue URI::InvalidURIError
        raise ArgumentError, "url must be a valid HTTP or HTTPS URL"
      end
    end

    include Media
    extend Media
    private_constant :Media
  end
end
