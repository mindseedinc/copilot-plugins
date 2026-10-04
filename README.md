# Plugin workspace

This workspace runs in a Debian 13 dev container with Apache, PHP, and a
separate MySQL service.

## Homepage

Open the forwarded Apache port (**Ports** panel, or `http://localhost:8080` if
you generated with `--port 8080`). The
[homepage](httpdocs/index.php) discovers every plugin manifest in `tools/*/plugin.json`
and the skills in each plugin's `skills/` directory. It includes documentation
links, requirements, CLI examples, and development toolchain availability.
New plugin folders appear automatically; curated usage examples for the current
plugins are defined in the homepage.

Apache and PHP serve the page, and a read-only `SELECT 1` checks MySQL on each
request with two-second connection/read timeouts. A failed check is shown
explicitly and logged in `/var/log/apache2/error.log`. The page does not execute
plugin commands, contact research providers, or display credentials.

## Tools

| Plugin | Purpose | Documentation |
| --- | --- | --- |
| `devcontainer-lamp` | Generate a Debian, Apache, PHP, Composer, Xdebug, and MySQL dev container. | [README](tools/devcontainer-lamp/README.md) |
| `social-search` | Search seven social networks through Social Searcher with Playwright; no API key. | [README](tools/social-search/README.md) |
| `social-crawl` | Web search, scraping, and public platform data through the SocialCrawl API. Requires an API key for API calls. | [README](tools/social-crawl/README.md) |

All three CLIs support local `--help`. Run the examples on the homepage from
the workspace root. Real research requests send queries to external providers;
never include private information.

The [marketplace.json](tools/social-search/marketplace.json) inside the
`social-search` plugin folder indexes it for the marketplace flow:

```sh
copilot plugin marketplace add /Users/workstage/Projects/plugins/tools/social-search
copilot plugin install social-search@social-search
```

Other tools register the same way by adding their own self-contained
`marketplace.json`, or individually via `chat.pluginLocations` — the
[workspace settings](.vscode/settings.json) currently register
`devcontainer-lamp` and `social-search`, and user settings may enable
additional plugins. These plugins provide skills and scripts, not MCP servers.

## Service checks

Run inside the dev container:

```sh
sudo --preserve-env=APACHE_DOCUMENT_ROOT apache2ctl configtest
curl --fail http://127.0.0.1/
mysqladmin --connect-timeout=5 ping
mysql --connect-timeout=5 --execute='SELECT VERSION(), DATABASE();'
docker info
```

Preserving `APACHE_DOCUMENT_ROOT` avoids misleading Apache configuration
warnings from `sudo`. MySQL is the sibling Compose service `db:3306`; it is
not expected to appear in the app container's Docker-in-Docker `docker ps`.
Xdebug connects to the IDE only when triggered, so an idle port 9003 is normal.

## Homepage tests

The tests use PHP itself and require no additional packages:

```sh
php -l httpdocs/index.php
php .devcontainer/tests/homepage.php
```

They check discovery, rendered tool coverage, HTML escaping, invalid database
settings, and explicit handling of malformed or missing manifests. The render
also performs the normal read-only MySQL health check.
