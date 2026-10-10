# v1 release verification

Verified October 10, 2026. Candidate version: **1.0.0**, unpublished.
Deferred features and design discussions are recorded in [v1-release-plans.md](v1-release-plans.md).

## Completed checks

- [x] Build and install the gem into an isolated temporary directory.
- [x] Run the installed package's full suite on Ruby 2.6.10, 2.7.3, and 3.3.8:
  **167 tests, 1,486 assertions, zero failures/errors/skips on each**.
  Command from the installed gem directory: `ruby -Ilib:test test/run.rb`.
- [x] Inspect package metadata: version 1.0.0, OpenAI and Gemini description,
  no runtime gem dependencies, both provider implementations and tests included.
  Packaging uses an explicit allowlist; no .env or local release research included.
- [x] Live OpenAI model list (133 models) and configured-model report: HTTP 200;
  all six configured models were listed.
- [x] Live Gemini model list (62 models) and configured-model report: HTTP 200;
  configured chat model was listed. Listing does not prove generation access.
- [x] Live chat and conversation continuation on both providers: HTTP 200;
  each successfully recalled a word from the previous response.
- [x] Live streaming on both providers: HTTP 200 with nonempty text;
  OpenAI yielded 19 chunks and Gemini yielded 2. Chunk counts are not guaranteed.
- [x] Live OpenAI moderation, embeddings, speech file creation, and transcription
  of that speech file: HTTP 200.
- [x] Earlier Gemini YouTube smoke test summarized
  `https://www.youtube.com/watch?v=DV69qh0BzoA` successfully.
- [x] Document provider support, legacy migration, raw output, model-check limits,
  YouTube/native chat equivalents, and deferred scope.
- [x] Add changelog and CI matrix for Ruby 2.6, 2.7, 3.3, and 3.4.
- [x] `git diff --check` passes.

Live generation checks used OpenAI's configured default and Gemini
`gemini-3.5-flash-lite`. The configured Gemini default remains
`gemini-3.8-flash`; it succeeded in earlier testing but also returned temporary
high-demand errors. Availability and quotas can change independently of the gem.

## Hardening performed

- Handle fragmented stream data and mixed LF/CRLF/CR SSE delimiters.
- Report failed/incomplete OpenAI generations as errors even with HTTP 200.
- Reject Gemini model-list error payloads even with HTTP 200.
- Fix empty keyword forwarding in legacy methods on Ruby 2.6; the installed
  package tests caught this compatibility issue and now pass.
- Use a portable test runner across supported Ruby versions.

## Remaining publication gates and coverage limits

- [ ] Run the GitHub Actions matrix after pushing; Ruby 3.4 and Linux CI have
  not been executed locally. No actual Rails application integration test was run.
- [ ] Review final diff and include new provider, test, CI, and documentation files
  when committing; `git commit -am` alone would omit untracked files.
- [ ] Date the changelog when publishing, rebuild from the final committed tree,
  tag v1.0.0, and publish only when requested. A GitHub push does not update RubyGems.
- OpenAI image generation has automated stub coverage but was not live-generated
  during this hardening pass. API failures and unusual stream frames are tested
  using fixtures/stubs, not induced against production providers.
- Candidate artifact: `/private/tmp/ai-lite-1.0.0.gem`; isolated installation:
  `/private/tmp/ai-lite-v1-final`. These temporary paths are verification outputs,
  not a persistent release archive.

No known failing local regression remains. Remote CI is still a publication gate;
this checklist does not claim every provider option or model has been live-tested.
