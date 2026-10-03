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

- `index.php` (the homepage) discovers plugins from `tools/*/plugin.json`;
  keep manifests valid so tools appear there.
- Run `php -l index.php` and `php .devcontainer/tests/homepage.php` after
  adding or changing plugin manifests.
