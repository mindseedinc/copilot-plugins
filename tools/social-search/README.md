# Social search

A GitHub Copilot Agent Plugins 1.0 package providing a `social-search` skill,
plugin-scoped instructions, and executable query code. It is not an MCP server
and does not contribute a separate callable entry to the Tools list.

## Provider

Social Searcher (https://www.social-searcher.com/) is a **provisional choice**
because the original request did not specify a site URL. Its current public
search embeds Google search results by network. The old `/api/` documentation
returned HTTP 404 during development, so this plugin uses the public browser
interface rather than assuming the historical API still works.

The script searches the site's network search pages with a browser. No API key
is required. Queries are sent to Social Searcher and Google; do not include
secrets or private information. The results are indexed public snippets, not
an exhaustive, real-time social feed. No login, CAPTCHA bypass, or pagination
is implemented.

## Setup

Run from this plugin directory:

```sh
npm ci
npm run setup:browser
```

Node.js 22 or newer is required. The dependency lockfile pins the installed
versions. Install Chromium again if upgrading Playwright.

Register this folder as a marketplace (its
[marketplace.json](marketplace.json) is self-contained) and install —
loads live from this folder; no path editing needed:

```sh
copilot plugin marketplace add /absolute/path/to/tools/social-search
copilot plugin install social-search@social-search
```

Alternatively, register this folder directly in settings:

```json
{
  "chat.plugins.enabled": true,
  "chat.pluginLocations": {
    "/absolute/path/to/tools/social-search": true
  }
}
```

Open **Chat: Open Customizations** > **Plugins** to check registration, and
**Skills** to find `social-search`. Start a new session after enabling it.
The plugin's instructions live under `com.github.copilot/rules/`.

Example chat request:

> Use social-search to find public Reddit discussions about GitHub Copilot.

## Direct usage

```sh
npm run search -- --query '"GitHub Copilot"' --network reddit --limit 5
```

Run the script directly if you need pure JSON stdout without npm's banner:

```sh
node skills/social-search/scripts/search.mjs --query "vscode" --network reddit --limit 3
```

Supported networks: Facebook, X (`twitter`), Instagram, TikTok, LinkedIn,
YouTube, and Reddit. Omit `--network` to search all seven sequentially.
`--limit` is per network (1-20; default 5) and applies only to the first page.
`--timeout` is per network in milliseconds (1000-120000; default 30000).
Use `--headed` to inspect browser behavior.

Successful output contains:

```json
{
  "provider": "Social Searcher",
  "query": "vscode",
  "searchedAt": "ISO-8601 timestamp",
  "searchUrl": "https://www.social-searcher.com/google-social-search/?q=vscode",
  "networks": [
    {
      "network": "reddit",
      "searchUrl": "https://www.social-searcher.com/redditcse.html?q=vscode",
      "status": "ok",
      "results": [
        {
          "title": "Result title",
          "url": "https://www.reddit.com/...",
          "snippet": "Indexed excerpt",
          "network": "reddit"
        }
      ]
    }
  ]
}
```

An explicit empty result page has `status: "no_results"` and `results: []`.
HTTP errors, unrendered results, and invalid layouts produce a nonzero exit
and an error on stderr. A failure on any network fails the entire request,
without outputting partial data as success. Respect access restrictions and
retry later rather than bypassing them.

## Validation

```sh
npm test
```

Tests use intercepted browser requests: no real search queries are sent.
For a live smoke test, run the direct usage example above.

## Distribution

Publish this directory as a repository root and install with **Chat: Install
Plugin From Source**. Consumers need the same dependency/browser setup.
Local npm dependencies are not part of the published source.

References:

- [VS Code agent plugins](https://code.visualstudio.com/docs/agent-customization/agent-plugins)
- [GitHub plugin authoring](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-creating)
- [Social Searcher](https://www.social-searcher.com/)
