---
name: devcontainer-lamp
description: Create a VS Code dev container (.devcontainer folder) for a project using Debian 13, Apache, the latest PHP, Composer, Xdebug and MySQL. Use when the user wants a PHP/LAMP development container or devcontainer setup.
---

# Dev container: Debian 13 + Apache + PHP + MySQL

Resolve paths relative to this skill's directory. The generator writes
`<project>/.devcontainer/`; it does not modify any other project files.

## Run

```sh
bash "<skill-directory>/scripts/create-devcontainer.sh" [options] "<project-dir>"
```

Options:

- `--php 8.5` — PHP major.minor. Default: latest stable from php.net.
- `--mysql 26.7` — MySQL image tag. Default: newest numeric tag on Docker Hub.
- `--docroot public` — web root relative to the project. Default: `public`
  when `public/index.php` exists, otherwise the project root.
- `--name`, `--db-name`, `--db-user`, `--db-password`, `--db-root-password`.
  Defaults: folder name, `app`, `app`, `app`, `root`.
- `--offline` — skip version lookups and use built-in defaults.
- `--force` — overwrite an existing `.devcontainer`. Ask the user first.
- `--open` — open the project in VS Code inside the container.

Pass user-provided values as quoted arguments. The script rejects unsafe
characters. Report its errors to the user instead of working around them.

## Result

- `app`: `debian:trixie` with Apache 2.4 (`mod_php`, running as `vscode`),
  PHP from packages.sury.org, Composer, Xdebug (trigger mode, port 9003),
  common CLI tools, and a MySQL client. Apache serves the web root on port 80.
- `db`: official `mysql` image with a persistent volume. SQL files in
  `.devcontainer/mysql/init/` run when the volume is first created.
  Oracle does not publish MySQL `.deb` packages for Debian 13 on arm64, which
  is why MySQL runs in its own container.
- The app container gets `DB_HOST=db`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`,
  and `DB_PASSWORD`. Running `mysql` with no arguments connects to the database.
- `.devcontainer/` files plus `.github/copilot-instructions.md` (a "Dev
  container" section between `devcontainer-lamp:begin/end` markers, merged
  idempotently — user content outside the markers is preserved).

Afterwards, tell the user to open the folder in VS Code and choose
**Reopen in Container**. The first build takes a few minutes.
