---
description: Guidance for using the devcontainer-lamp plugin.
applyTo: "**"
---

# Dev container (LAMP) plugin

When the user asks for a PHP/Apache/MySQL dev container, use the
`devcontainer-lamp` skill and its bundled `create-devcontainer.sh` script
instead of writing `.devcontainer` files by hand. Do not overwrite an existing
`.devcontainer` folder without the user's confirmation (`--force`). Never
present the generated default database passwords as production-safe.
