# social-crawl plugin - developer notes

Agent Plugins 1.0 package exposing the SocialCrawl API to Copilot agents through a
skill, an instruction rule, and a Python tool. **No MCP servers, no JavaScript.**

## Key files

| File | Role |
| --- | --- |
| `plugin.json` | Manifest. Only standard fields; `$schema` must stay the Agent Plugins 1.0 URL. |
| `skills/social-crawl/SKILL.md` | Agent-facing instructions. `name` must match the folder. |
| `skills/social-crawl/scripts/socialcrawl.py` | CLI tool covering every REST endpoint. |
| `skills/social-crawl/scripts/credentials.py` | Key resolution: env var, plugin `.env`, `~/.config/socialcrawl/api_key`. |
| `skills/social-crawl/references/` | Longer playbooks loaded on demand. |
| `com.github.copilot/rules/*.instructions.md` | Copilot-specific always-on rule. |
| `tests/test_socialcrawl.py` | `python3 -m unittest discover -s tests` |

## Conventions

- Python 3.9+, standard library only (`urllib.request`, `argparse`, `json`). No pip installs.
- Never print, log, or place the API key in URLs or files. Send it only as `x-api-key`.
- Keep HTTP behind the injectable `transport` so tests never touch the network.
- Branch on the envelope's `success` and `error.type`; retry only when
  `error.retryable` is true and the request is repeatable.
- Prefer the live catalogue (`/v1/utility/*`, free) over hard-coded endpoint lists.
- Keep `SKILL.md` concise; move long material to `references/`.
