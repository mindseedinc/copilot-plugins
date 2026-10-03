# social-crawl: a GitHub Copilot agent plugin

Gives any agent in VS Code (and the Copilot CLI) live public data from across the
internet through the [SocialCrawl API](https://www.socialcrawl.dev/docs): web search
and scraping, news, trends, and 60+ platforms including Reddit, YouTube, TikTok, X,
Instagram, LinkedIn, Hacker News, GitHub, Amazon, app stores, Trustpilot, G2, Yelp,
jobs, and finance.

The plugin uses only a **skill**, an **instruction rule**, and a **Python tool**
(standard library only). It has no MCP server and no JavaScript.

## Layout (Agent Plugins 1.0)

```text
social-crawl/
├── plugin.json                         # Manifest ($schema selects Agent Plugins 1.0)
├── .env                                # Your API key (gitignored, never committed)
├── .env.example                        # Template for .env
├── skills/social-crawl/
│   ├── SKILL.md                        # When and how agents use the tool
│   ├── scripts/socialcrawl.py          # The tool: CLI for every SocialCrawl endpoint
│   ├── scripts/credentials.py          # Key loading (.env, environment, ~/.config)
│   └── references/research-workflows.md
├── com.github.copilot/rules/
│   └── social-crawl.instructions.md    # Always-on guidance: when to reach for the skill
└── tests/test_socialcrawl.py
```

VS Code discovers skills from `skills/` and Copilot-specific instructions from
`com.github.copilot/rules/`. See
[Agent plugins in VS Code](https://code.visualstudio.com/docs/agent-customization/agent-plugins).

## Setup

1. Requirements: Python 3.9+ on `PATH` as `python3` (or `python`). Nothing to install.
2. Credentials: copy the template and paste your key (create one at
   <https://www.socialcrawl.dev/dashboard>, 100 free credits):

   ```sh
   cp .env.example .env
   chmod 600 .env
   # edit .env: SOCIALCRAWL_API_KEY=sc_...
   ```

   The tool checks, in order: `$SOCIALCRAWL_API_KEY`, this folder's `.env`, then
   `~/.config/socialcrawl/api_key`. The key is sent only in the `x-api-key` header
   and is never printed.
3. Verify (0 credits):

   ```sh
   python3 skills/social-crawl/scripts/socialcrawl.py balance
   ```

## Use it across all projects

Register the plugin folder once in your **User** settings (`Preferences: Open User
Settings (JSON)`), not a workspace settings file:

```json
{
  "chat.plugins.enabled": true,
  "chat.pluginLocations": {
    "/Users/workstage/Projects/plugins/tools/social-crawl": true
  }
}
```

Alternatively run **Chat: Install Plugin From Source** and enter this folder's path
or its Git URL. Then start a new chat session and check **Chat: Open
Customizations** > **Plugins** (the plugin), **Skills** (`social-crawl`), and
**Instructions** (`social-crawl.instructions.md`).

Example prompts:

- "What are Reddit and YouTube users saying about the Rivian R2? Cite sources."
- "Search the web for the latest EU AI Act enforcement dates and summarise them."
- "Scrape https://example.com/pricing and list the plans."

## Tool reference

```sh
S=skills/social-crawl/scripts/socialcrawl.py
python3 $S --help
python3 $S endpoints --search reviews            # free catalogue search (compact)
python3 $S endpoint reddit/search                # free: params, cost, paging
python3 $S plan "Monitor mentions of Acme"       # free: ordered calls with prices
python3 $S web-search "query" limit=10           # 2 credits per 10 results
python3 $S scrape "https://example.com"          # 1 credit
python3 $S search forums "query"                 # 10 credits
python3 $S call reddit/search "query=x" trim=true --pages 2 --output /tmp/socialcrawl/x.json
```

Commands: `balance`, `endpoints`, `endpoint`, `plan`, `capabilities`, `llms`,
`call`, `search <everywhere|forums|creators|news|multi>`, `web-search`, `scrape`.
Options: `--pages`, `--method`, `--body`, `--idempotency-key`, `--output`,
`--timeout`. Exit codes: `0` success, `1` usage/config/network, `2` API error.

### Migrating from `socialcrawl_reviews.py`

| Old | New |
| --- | --- |
| `--query "X review"` (Reddit + YouTube) | `search multi "X review" platforms=reddit,youtube` or `search forums "X review"` |
| `--include-tiktok` | add `tiktok` to `platforms=` |
| `--type profile --query sub` | `call reddit/subreddit subreddit=sub` (check `endpoint reddit/subreddit`) |
| `--max-results N` | `limit=N` where the endpoint supports it, `--pages N` |
| `--output-json` | `--output` |
| Markdown report | The agent writes the report using `references/research-workflows.md` |

## Development

```sh
python3 -m unittest discover -s tests -v
```

Tests use a fake transport and temporary credential files; they make no network
calls and never read your real `.env`.

## Security

- `.env` is gitignored; keep it `chmod 600`. Rotate the key in the dashboard if it is
  ever exposed.
- The tool only calls `https://www.socialcrawl.dev`, rejects full URLs as paths,
  refuses redirects (so the key header is never forwarded), and refuses credential
  query parameters.
- Agents are instructed to treat fetched content as untrusted and to ask before
  expensive or recurring calls.
