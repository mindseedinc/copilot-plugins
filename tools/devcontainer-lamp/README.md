# devcontainer-lamp

This tool creates a VS Code dev container in any project:

| Service | What runs in it |
|---------|-----------------|
| `app` | **Debian 13 (trixie)** with **Apache 2.4**, the **latest PHP** from [packages.sury.org](https://packages.sury.org/php/), Composer, Xdebug, and common dev tools (git, curl, build-essential, jq, sudo, MySQL client, …) |
| `db` | **MySQL**: the latest official `mysql` image, with a persistent volume |

MySQL runs in its own container because Oracle does not publish MySQL `.deb`
packages for Debian 13 on arm64 (Apple Silicon). The official image supports
amd64 and arm64.

## Usage

```sh
# From inside a project:
/path/to/tools/devcontainer-lamp/create-devcontainer.sh

# Or target a project and open it in the container right away:
/path/to/tools/devcontainer-lamp/create-devcontainer.sh --open ~/Projects/my-site
```

The script writes these files to `<project>/.devcontainer/`:

```text
.devcontainer/
├── devcontainer.json    # VS Code config: compose, ports, extensions, post-create
├── compose.yaml         # app (Debian 13) + db (MySQL) services
├── Dockerfile           # Debian 13 + Apache + PHP + Composer + tools
├── apache-vhost.conf    # DocumentRoot = $APACHE_DOCUMENT_ROOT, AllowOverride All
├── php-dev.ini          # dev php.ini overrides and Xdebug settings
├── mysql-client.cnf     # makes the mysql CLI connect to the db service
├── entrypoint.sh        # starts Apache when the container starts
├── post-create.sh       # composer install and ~/.my.cnf
├── mysql/init/          # *.sql / *.sql.gz / *.sh seed files run on first DB start
└── .gitattributes       # keeps scripts on LF line endings
```

It also writes `<project>/.github/copilot-instructions.md` with a
"Dev container" section for agents (services, docroot, port, DB connection,
logs, volume). The section is wrapped in `<!-- devcontainer-lamp:begin/end -->`
markers: rerunning the script updates only that section and leaves the rest
of the file untouched. A file without markers gets the section appended; the
script never overwrites unrelated content.

Open the project in VS Code and choose **Reopen in Container**. VS Code
suggests this when it finds `.devcontainer/devcontainer.json`. `--open` skips
that prompt. Commit `.devcontainer/` so everyone on the project gets the same
environment.

To make the tool available everywhere:

```sh
ln -s /path/to/tools/devcontainer-lamp/create-devcontainer.sh ~/bin/create-lamp-devcontainer
```

### Options

| Option | Default |
|--------|---------|
| `--php VERSION` | latest stable PHP from php.net (currently 8.5) |
| `--mysql TAG` | newest numeric `mysql` tag on Docker Hub (currently 26.7) |
| `--port PORT` | none — VS Code auto-forwards port 80 to a free local port (avoids conflicts between projects); pass e.g. `--port 8080` to pin |
| `--app-dir NAME` | `httpdocs` — app folder bound to `/var/www/httpdocs` |
| `--docroot PATH` | `public` if `public/index.php` exists, else the app folder |
| `--name NAME` | project folder name (used for the Compose project name) |
| `--db-name` / `--db-user` / `--db-password` | `app` / `app` / `app` |
| `--db-root-password` | `root` |
| `--offline` | skip version lookups and use the built-in defaults |
| `--force` | overwrite an existing `.devcontainer` |
| `--open` | open VS Code inside the container (needs the `code` CLI) |

The script looks up the latest versions once, when it runs, and writes them
into the files. The environment stays the same until you regenerate it or
edit `PHP_VERSION` / `image: mysql:…` in `compose.yaml`.

## Ports, volumes and bind mounts

By default Apache is **not** published on a fixed host port: VS Code auto-forwards
container port 80 and picks a free local port, so multiple projects can run at
the same time. The URL shows in VS Code's **Ports** panel. Pass `--port 8080`
to pin it.

State is split by what it needs:

| Where | What | Why |
|-------|------|-----|
| named Docker volume `<project>-devcontainer_mysql-data` | MySQL database files | persists across rebuilds and `docker compose down`; survives container recreation; faster than a host bind on macOS/Windows |
| `httpdocs/` (or `--app-dir`) → `/var/www/httpdocs` | application files | live with the code, editable on the host; Apache docroot and VS Code workspace folder |
| `logs/errors/apache/` → `/var/log/apache2` | Apache `error.log` | easy to inspect on the host |
| `logs/errors/mysql/` → `/var/log/mysql` | MySQL `error.log` | easy to inspect on the host |

The volume name is deterministic (Compose project name + `_mysql-data`), so
the same project always reuses its data. `logs/` gets a `.gitignore` (`*`) so
logs are never committed. The whole project is also mounted at `/workspace`,
so `.devcontainer` and tooling stay reachable.

To reset the database: `docker volume rm <project>-devcontainer_mysql-data`
(run `docker compose -p <project>-devcontainer down` first).

Layouts where the docroot sits inside the project (Laravel, Symfony — detected
via `public/index.php`, or forced with `--docroot`) keep serving from
`/workspace/<docroot>` and keep the workspace folder at `/workspace`, because
binding only `public/` would break `../vendor` includes. They still get the
volume and the `logs/` binds.

## Inside the container

- Apache runs on port 80 as the `vscode` user, so the app can write to the
  workspace. VS Code forwards the port to your machine. Dotfiles and dot
  folders (`.env`, `.git`, `.devcontainer`, …) return 403; only `.well-known`
  is allowed. Restart Apache with
  `sudo apache2ctl restart`. Logs are in `/var/log/apache2/`.
- Change the web root with `APACHE_DOCUMENT_ROOT` in `compose.yaml`, then rebuild.
- Database settings are in the environment (`DB_HOST=db`, `DB_PORT`,
  `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `DB_CONNECTION=mysql`). These
  are the names Laravel uses. Running `mysql` with no arguments opens the
  database, and `mysqldump` works too. VS Code also forwards `db:3306`, and a
  SQLTools connection is preconfigured.
- Xdebug runs in trigger mode on port 9003. Set `XDEBUG_TRIGGER` (a browser
  extension can do this) and start the **PHP Debug** listener.
- Add more tools with Dev Container Features in `devcontainer.json`, for
  example Node.js.
- To reset the database, rebuild without cache, or run
  `docker compose -p <name>-devcontainer down -v` from your machine.

The default credentials are for local development only.

## Copilot plugin

This folder is also a GitHub Copilot agent plugin with a
`devcontainer-lamp` skill. To register it, add its absolute path to
`chat.pluginLocations` in the workspace
[settings](../../.vscode/settings.json). Then you can ask Copilot:

> Use devcontainer-lamp to add a dev container to this project.

## Tests

```sh
tests/smoke-test.sh          # needs Docker + Node.js (uses npx @devcontainers/cli)
tests/smoke-test.sh --keep   # leave the container and project for inspection
```

The smoke test generates a temporary project and starts it with the Dev
Containers CLI. It checks Debian 13, the PHP version and extensions, Composer,
Apache (and its user), the MySQL CLI and `mysqldump`, an HTTP request that
runs PHP and queries MySQL, the default auto-forwarded port (no `ports:` in
compose; run with `PINNED_PORT=1` to check the `--port` mode), the MySQL named
volume, the host-side `logs/errors/*` binds, the framework
(`public/index.php`) layout, and the generated
`.github/copilot-instructions.md` (rendered values, idempotent rerun, user
content preserved). It removes the containers and volume afterwards.
