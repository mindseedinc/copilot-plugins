# Workspace: plugin creation

This workspace creates Copilot agent plugins. Each folder under `tools/` is one
self-contained plugin: `social-search`, `social-crawl`, and `devcontainer-lamp`.

## What plugins are

An agent plugin is a portable folder that extends Copilot with **skills**
(instructions plus scripts an agent can invoke), rules, agents, and MCP server
definitions. A plugin is any folder with a `plugin.json` manifest at its root.
VS Code and the Copilot CLI discover plugins either directly (via settings) or
through a **marketplace** — an index file (`marketplace.json`) that lists
installable plugins and where each one lives.

## Plugin anatomy (per tool folder)

```
tools/<plugin-name>/
  plugin.json                          # manifest: name, version, description
  marketplace.json                     # optional: self-marketplace (source: ".")
  skills/<skill-name>/SKILL.md         # skill: YAML frontmatter (name,
                                       #   description) + how to run it
  skills/<skill-name>/scripts/         # scripts the skill invokes
  com.github.copilot/rules/*.md        # Copilot-specific rules
  tests/                               # plugin's own test suite
  README.md                            # usage and registration docs
```

- `plugin.json` must declare `$schema`
  `https://agent-plugins.org/schemas/1.0.0/plugin.schema.json` and a lowercase
  kebab-case `name` matching the folder name.
- `SKILL.md` frontmatter needs `name` and `description`; the description
  determines when the agent picks the skill.
- Scripts must resolve paths relative to the skill directory, never the user's
  active project. Install plugin dependencies inside the plugin folder only.

## Creating a new plugin

1. Copy the structure above into `tools/<plugin-name>/` (use an existing tool
   as the template).
2. Write `plugin.json`, the skill(s), and tests; validate with the tests.
3. If the plugin should be installable via the marketplace flow, add a
   self-contained `marketplace.json` (see `tools/social-search/marketplace.json`):

   ```json
   {
     "name": "<plugin-name>",
     "owner": { "name": "workstage" },
     "plugins": [{ "name": "<plugin-name>", "version": "…", "description": "…", "source": "." }]
   }
   ```

4. Run the plugin's test suite before registering it.

## Installing and using plugins

From the workspace root, using the bundled Copilot CLI (or the VS Code
**Chat: Open Customizations > Plugins** view):

```sh
copilot plugin marketplace add /Users/workstage/Projects/plugins/tools/<plugin-name>
copilot plugin install <plugin-name>@<plugin-name>
copilot plugin list
```

Local plugins load live from their folder — edits apply on the next chat
session, nothing is copied. Alternatively, register plugin folders directly in
`chat.pluginLocations` (workspace or user settings) without a marketplace.

Use a plugin by asking for it in chat (for example: "Use social-search to find
public Reddit discussions about X"); the agent loads the matching `SKILL.md`
and runs its scripts. Each tool README documents its skill's arguments.

## Related workspace behavior

- `httpdocs/index.php` (the homepage, served at http://localhost:8080 in the
  dev container) discovers plugins from `tools/*/plugin.json`;
  keep manifests valid so tools appear there.
- Run `php -l httpdocs/index.php` and `php .devcontainer/tests/homepage.php`
  after adding or changing plugin manifests.
- `httpdocs/` (app files) and `logs/errors/` are bind-mounted from the host
  by `.devcontainer/compose.yaml`; MySQL data lives in the named volume
  `plugins-devcontainer_mysql-data`. `logs/` is git-ignored.
  `.devcontainer/apache-vhost.conf` contains
  hand-added `/tools` aliases — re-add them after regenerating with
  `create-devcontainer.sh --force`.

<!-- devcontainer-lamp:begin -->
## Dev container

This project has a dev container (`.devcontainer/`): open the folder in VS
Code and choose **Reopen in Container**. First build takes a few minutes.

| Service | What it is |
|---------|------------|
| `app` | Debian 13 with Apache 2.4, PHP 8.5 (mod_php), Composer, Xdebug; runs as user `vscode` |
| `db` | MySQL 26.7 (official image) |

### Working in the container

- Apache serves `/var/www/httpdocs` (httpdocs/ on the host, bound to
  /var/www/httpdocs). Port 80 is auto-forwarded to a free local port (see VS Code's Ports panel).
  Restart Apache with `sudo apache2ctl restart`; its error log is at
  `logs/errors/apache/error.log` on the host.
- The whole project is also mounted at `/workspace` (`.devcontainer/`,
  tooling, framework files outside the app dir).
- MySQL: host `db`, database `app`, user `app` (password and
  other credentials are in `.devcontainer/compose.yaml` and the `DB_*`
  environment variables). Running `mysql` with no arguments opens the
  database. The error log is at `logs/errors/mysql/error.log` on the host.
- MySQL data persists in the named volume
  `plugins-devcontainer_mysql-data`. Reset the database with
  `docker compose -p plugins-devcontainer down -v` (also removes
  seed re-runs). SQL files in `.devcontainer/mysql/init/` run only when the
  volume is first created.
- PHP dev settings and Xdebug (trigger mode, port 9003) are in
  `.devcontainer/php-dev.ini`; start listening in VS Code and set
  `XDEBUG_TRIGGER` to debug.
- Dotfiles (`.env`, `.git`, `.devcontainer`, …) are never served by Apache.

Generated by `devcontainer-lamp`; edit outside the markers — rerunning the
tool updates only this section.
<!-- devcontainer-lamp:end -->
