# AI Lite

AI Lite is a pure Ruby, dependency-light client for simple chat-style calls through OpenAI's Responses API.

It is built for Rails apps and plain Ruby projects where installing a full OpenAI SDK is too heavy, incompatible, or unnecessary. It is especially useful in legacy Rails apps where Rails, ActiveSupport, Ruby, or HTTP-client dependency constraints make larger client libraries difficult to add.

Use AI Lite when you want a small OpenAI client that works without tying your app to a specific Rails version or a larger dependency stack.

This gem is intentionally small:

- No Rails dependency
- No official OpenAI gem dependency
- No Faraday, HTTParty, ActiveSupport, or connection pool dependency
- Uses only Ruby stdlib: `Net::HTTP`, `URI`, and `JSON`

It is not meant to replace the official OpenAI SDK. It is a small wrapper for projects that only need one clean interface:

```ruby
ai.chat("Say hello")
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

## Return Shape

`chat` always returns a hash envelope.

Text output:

```ruby
{
  "content" => "Hello!",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

JSON-looking model output:

```ruby
{
  "content" => { "valid" => true },
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

Failure:

```ruby
{
  "content" => nil,
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
