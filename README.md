# AI Lite

AI Lite is a pure Ruby, dependency-light client for simple OpenAI API calls.

It is built for Rails apps and plain Ruby projects where installing a full OpenAI SDK is too heavy, incompatible, or unnecessary. It is especially useful in legacy Rails apps where Rails, ActiveSupport, Ruby, or HTTP-client dependency constraints make larger client libraries difficult to add.

Use AI Lite when you want a small OpenAI client that works without tying your app to a specific Rails version or a larger dependency stack.

This gem is intentionally small:

- No Rails dependency
- No official OpenAI gem dependency
- No Faraday, HTTParty, ActiveSupport, or connection pool dependency
- Uses only Ruby stdlib: `Net::HTTP`, `URI`, `JSON`, and `Base64`

It is not meant to replace the official OpenAI SDK. It is a small wrapper for projects that only need a few clean interfaces:

```ruby
ai.chat("Say hello")
ai.moderate("User submitted text")
```

## Usage

```ruby
require "ai_lite"

ai = AiLite.new
result = ai.chat("Say hello")

puts result["content"]
```

By default, the client looks for an API key in `OPENAI_API_KEY`, then falls back to `OPEN_AI_TOKEN`.

You can also pass the key directly:

```ruby
ai = AiLite.new(api_key: "sk-...")
```

## Configuration

In Rails, configure the default client from an initializer:

```ruby
# config/initializers/ai_lite.rb
AiLite.configure do |config|
  config.api_key = ENV["OPENAI_API_KEY"]
  config.model = "gpt-5.5"
  config.moderation_model = "omni-moderation-latest"
  config.timeout = 120
  config.max_output_tokens = 2000
end
```

Then use the configured singleton-style client:

```ruby
result = AiLite.chat("Say hello")
```

You can still instantiate a separate client for another token:

```ruby
client = AiLite.new(api_key: "sk-other-token")
result = client.chat("Say hello")
```

## Chat

```ruby
result = ai.chat(
  "Return JSON confirming whether this is valid.",
  instructions: "Return only minified JSON.",
  max_output_tokens: 500,
  options: {
    text: { verbosity: "low" }
  }
)
```

`chat` sends a `POST` request to `/v1/responses` with:

- `model`
- `input`
- `max_output_tokens`
- optional `instructions`
- optional `debug`
- optional extra `options`

The default model is `gpt-5.5`.

The OpenAI API URL is fixed to `https://api.openai.com/v1/responses`.

## Moderation

Use `moderate` to classify user-submitted text or images for potentially harmful content before saving, publishing, or sending it into another AI call.

A common use case is checking a comment before it is shown publicly:

```ruby
comment = "User submitted comment"
result = ai.moderate(comment)

if result["content"]["flagged"]
  # hide, block, or route the comment to review
else
  # publish the comment
end
```

Moderation responses include an overall `flagged` value plus category booleans and scores:

```ruby
{
  "content" => {
    "flagged" => false,
    "categories" => {
      "hate" => false,
      "violence" => false
    },
    "category_scores" => {
      "hate" => 0.01,
      "violence" => 0.02
    }
  },
  "response_id" => "modr_...",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

`moderate` sends a `POST` request to `/v1/moderations` with:

- `model`
- `input`
- optional extra `options`

The default moderation model is `omni-moderation-latest`.

You can pass an image URL:

```ruby
result = ai.moderate(
  text: "Profile caption",
  image_url: "https://example.com/image.png"
)
```

Or a local image path:

```ruby
result = ai.moderate(image_path: "tmp/upload.png")
```

Local images are read, base64 encoded, and sent as JSON data URLs. They do not use multipart uploads. Supported local image extensions are `.gif`, `.jpeg`, `.jpg`, `.png`, and `.webp`.

You can also pass OpenAI's raw moderation input shape directly:

```ruby
result = ai.moderate([
  { type: "text", text: "Caption" },
  {
    type: "image_url",
    image_url: {
      url: "https://example.com/image.png"
    }
  }
])
```

## Multi-Turn Chat

Responses include a `response_id` that can be passed back through `options` as `previous_response_id`:

```ruby
first = ai.chat("Tell me a short joke.")

follow_up = ai.chat(
  "Explain why that is funny.",
  options: {
    previous_response_id: first["response_id"]
  }
)

puts follow_up["content"]
```

## Return Shape

Methods return a hash envelope.

Text output:

```ruby
{
  "content" => "Hello!",
  "response_id" => "resp_...",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

JSON-looking model output:

```ruby
{
  "content" => { "valid" => true },
  "response_id" => "resp_...",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

Failure:

```ruby
{
  "content" => nil,
  "response_id" => nil,
  "status" => 401,
  "error" => "Invalid API key",
  "raw" => nil
}
```

Pass `debug: true` to include the raw OpenAI response:

```ruby
result = ai.chat("Say hello", debug: true)

{
  "content" => "Hello!",
  "response_id" => "resp_...",
  "status" => 200,
  "error" => nil,
  "raw" => { ... }
}
```

## Development

Run the test suite:

```sh
ruby -Ilib:test test/ai_lite_test.rb
```
