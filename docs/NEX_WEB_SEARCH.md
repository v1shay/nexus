# Nex Web Search

Nex can decide that a prompt needs live information, formulate a query, search public providers, read the strongest pages, and stream a sourced answer through the existing notch tool lifecycle.

## Runtime flow

1. While Nex speaks the normal acknowledgement, the selected local/remote model returns a strict `use_web` decision and one concise query.
2. `web_search` executes through `NexToolRegistry` with network permission.
3. The compact notch displays the Chrome icon and real lifecycle stages: **Searching the web…**, **Reviewing results…**, **Reading sources…**, and **Synthesizing findings…**.
4. Ranked evidence is inserted as untrusted data immediately before answer generation. The normal model-token and Piper speech streams then continue unchanged.
5. The expanded response retains a **Used search · N sources** receipt. Click it to inspect excerpts or open the actual source URL.

The planner searches for recent/changing facts, explicit lookup or verification, current events, prices, versions, documentation, products, research, and named webpages. It is instructed not to search for casual conversation, creative/transformative writing, personal memory, or stable facts it confidently knows. A deterministic fallback still catches obvious current/search wording if the planner model fails.

## Providers and configuration

The default fallback order is:

1. A configured SearXNG instance.
2. Bing RSS search.
3. Google News RSS when more results are needed.

No paid API key is required. To prefer a self-hosted SearXNG server, set this environment variable in the Nexus scheme or LaunchAgent environment:

```text
NEXUS_SEARXNG_URL=https://search.example.net
```

Provider adapters implement `NexWebSearchProviding`; page readers implement `NexWebPageReading`. Neither the model-facing schema nor the overlay changes when another adapter is added.

## Safety and reliability

- Identical normalized queries share in-flight work and are cached for ten minutes.
- Results are ranked, canonicalized, and deduplicated before page reads.
- Three top pages are read concurrently; failed reads remain explicitly `fetch_failed` and only their search snippet is retained.
- Requests have bounded timeouts, connection concurrency, a 2 MB page limit, and a 12,000-character extraction limit.
- Only public HTTP(S) URLs are accepted. Credentials, loopback, link-local, private-network, internal hostnames, unsafe DNS resolutions, and unsafe redirects are rejected.
- Scripts, navigation, forms, headers, footers, sidebars, and markup are stripped before evidence reaches the model.
- Provider or page failures return partial honest results when possible; no result is fabricated.
- Cancelling/dismissing the response cancels the planner, search, page reads, model stream, and existing TTS path together.

## Tests

Run deterministic unit and regression tests:

```bash
xcodebuild -project nexus/nexus.xcodeproj -scheme nexus -destination 'platform=macOS' \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test -only-testing:nexusTests
```

`NexWebSearchTests` covers planning, non-search behavior, extraction, SSRF rejection, ranking, deduplication, caching, staged lifecycle output, Chrome receipt rendering, and structured evidence. The opt-in live test can be temporarily enabled in Xcode to exercise public providers; it is skipped by default so ordinary tests do not depend on the internet.

Useful manual prompts:

- “What are the latest updates on the new virus outbreak spreading right now?”
- “What changed in the newest Swift release?”
- “Look up today’s biggest AI news and summarize the two most important stories.”
- “Verify the current Ollama macOS installation instructions.”
- “Give me a five-minute workout on my bed.” — should answer normally without searching.
