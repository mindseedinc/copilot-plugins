<?php
declare(strict_types=1);

function html(string|int $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function workspacePlugins(string $directory): array
{
    if (!is_dir($directory)) {
        throw new RuntimeException('The workspace tools directory is missing.');
    }

    $manifests = glob($directory . '/*/plugin.json');
    if ($manifests === false) {
        throw new RuntimeException('The workspace plugin manifests could not be listed.');
    }

    $plugins = [];
    foreach ($manifests as $manifestPath) {
        $contents = file_get_contents($manifestPath);
        if ($contents === false) {
            throw new RuntimeException('A workspace plugin manifest could not be read.');
        }
        $manifest = json_decode($contents, true, 512, JSON_THROW_ON_ERROR);
        foreach (['name', 'version', 'description'] as $field) {
            if (!is_array($manifest) || !isset($manifest[$field])
                || !is_string($manifest[$field]) || trim($manifest[$field]) === '') {
                throw new RuntimeException('A workspace plugin manifest has an invalid ' . $field . '.');
            }
        }

        $pluginDirectory = dirname($manifestPath);
        $slug = basename($pluginDirectory);
        $url = '/tools/' . rawurlencode($slug);
        $skillPaths = glob($pluginDirectory . '/skills/*/SKILL.md');
        if ($skillPaths === false) {
            throw new RuntimeException('The skills for ' . $slug . ' could not be listed.');
        }
        $skills = [];
        foreach ($skillPaths as $skillPath) {
            $name = basename(dirname($skillPath));
            $skills[] = [
                'name' => $name,
                'url' => $url . '/skills/' . rawurlencode($name) . '/SKILL.md',
            ];
        }

        $plugins[] = [
            'slug' => $slug,
            'name' => $manifest['name'],
            'version' => $manifest['version'],
            'description' => $manifest['description'],
            'url' => $url . '/',
            'readme' => is_file($pluginDirectory . '/README.md') ? $url . '/README.md' : null,
            'skills' => $skills,
        ];
    }

    return $plugins;
}

function workspaceDatabaseHealth(): array
{
    if (!extension_loaded('mysqli')) {
        error_log('Workspace homepage: the mysqli extension is unavailable.');
        return ['ok' => false, 'detail' => 'The mysqli PHP extension is missing.'];
    }

    $host = getenv('DB_HOST');
    $port = getenv('DB_PORT');
    $database = getenv('DB_DATABASE');
    $username = getenv('DB_USERNAME');
    $password = getenv('DB_PASSWORD');
    if ($host === false || $host === '' || $port === false || !ctype_digit($port)
        || (int) $port < 1 || (int) $port > 65535 || $database === false || $database === ''
        || $username === false || $username === '' || $password === false) {
        error_log('Workspace homepage: database environment settings are missing or invalid.');
        return ['ok' => false, 'detail' => 'Check the DB_* environment settings in the dev container.'];
    }

    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $connection = null;
    try {
        $connection = mysqli_init();
        if ($connection === false
            || !$connection->options(MYSQLI_OPT_CONNECT_TIMEOUT, 2)
            || !$connection->options(MYSQLI_OPT_READ_TIMEOUT, 2)) {
            throw new RuntimeException('The database health check could not be initialized.');
        }
        $connection->real_connect($host, $username, $password, $database, (int) $port);
        $result = $connection->query('SELECT 1');
        if (!$result instanceof mysqli_result) {
            throw new RuntimeException('The database health query did not return a result.');
        }
        $result->free();
        return ['ok' => true, 'detail' => 'MySQL ' . $connection->server_info . ' at ' . $host . ':' . $port];
    } catch (mysqli_sql_exception | RuntimeException $error) {
        error_log('Workspace homepage: MySQL health check failed: ' . $error->getMessage());
        return ['ok' => false, 'detail' => 'Connection failed. Check the db service and Apache error log.'];
    } finally {
        if ($connection instanceof mysqli) {
            $connection->close();
        }
    }
}

function workspaceCommandAvailable(string $command): bool
{
    $path = getenv('PATH');
    if ($path === false || $path === '') {
        throw new RuntimeException('PATH is unavailable; CLI tool availability cannot be checked.');
    }
    foreach (explode(PATH_SEPARATOR, $path) as $directory) {
        if ($directory !== '' && is_file($directory . '/' . $command)
            && is_executable($directory . '/' . $command)) {
            return true;
        }
    }
    return false;
}

$toolDetails = [
    'devcontainer-lamp' => [
        'title' => 'Devcontainer LAMP',
        'category' => 'Development environment',
        'features' => ['Debian 13', 'Apache + PHP', 'Composer + Xdebug', 'Persistent MySQL'],
        'requirements' => 'Bash to generate; Docker and VS Code Dev Containers to run the result.',
        'note' => 'Creates a project .devcontainer directory. Use --offline to skip version lookups; --force overwrites existing configuration.',
        'commands' => [
            'bash tools/devcontainer-lamp/create-devcontainer.sh --help',
            'bash tools/devcontainer-lamp/create-devcontainer.sh --offline /path/to/project',
        ],
    ],
    'social-crawl' => [
        'title' => 'SocialCrawl',
        'category' => 'Web + platform research',
        'features' => ['Web search + scraping', '60+ platforms', 'News, reviews + finance', 'Live API catalogue'],
        'requirements' => 'Python 3.9+ and a SOCIALCRAWL_API_KEY for API calls. No Python packages to install.',
        'note' => 'Local --help needs no key or network. Discovery calls are free; data calls may use API credits. Keep credentials private.',
        'operations' => ['balance', 'endpoints', 'endpoint', 'plan', 'capabilities', 'llms', 'call', 'search', 'web-search', 'scrape'],
        'commands' => [
            'python3 tools/social-crawl/skills/social-crawl/scripts/socialcrawl.py --help',
            'python3 tools/social-crawl/skills/social-crawl/scripts/socialcrawl.py endpoints --search reviews',
        ],
    ],
    'social-search' => [
        'title' => 'Social Search',
        'category' => 'Public social search',
        'features' => ['7 supported networks', 'Browser-based search', 'JSON results', 'No API key'],
        'requirements' => 'Node.js 22+, the plugin npm dependencies, and Playwright Chromium.',
        'note' => 'Searches indexed public snippets through Social Searcher and Google, not an exhaustive live feed. Never submit private information.',
        'operations' => ['Facebook', 'X (twitter)', 'Instagram', 'TikTok', 'LinkedIn', 'YouTube', 'Reddit'],
        'commands' => [
            'node tools/social-search/skills/social-search/scripts/search.mjs --help',
            'node tools/social-search/skills/social-search/scripts/search.mjs --query "public topic" --network reddit --limit 5',
        ],
    ],
];

$plugins = [];
$catalogueError = null;
$toolchain = [];
$toolchainError = null;
try {
    $plugins = workspacePlugins(__DIR__ . '/tools');
} catch (JsonException | RuntimeException $error) {
    error_log('Workspace homepage: plugin catalogue failed: ' . $error->getMessage());
    $catalogueError = 'The plugin catalogue could not be loaded. Check the Apache error log.';
    http_response_code(500);
}
try {
    foreach (['php', 'composer', 'node', 'npm', 'python3', 'docker', 'mysql', 'mysqldump', 'git', 'curl', 'jq', 'make', 'gcc', 'g++'] as $command) {
        $toolchain[$command] = workspaceCommandAvailable($command);
    }
} catch (RuntimeException $error) {
    error_log('Workspace homepage: ' . $error->getMessage());
    $toolchainError = $error->getMessage();
}
$databaseHealth = workspaceDatabaseHealth();
$skillCount = array_sum(array_map(static fn (array $plugin): int => count($plugin['skills']), $plugins));

header('Content-Type: text/html; charset=UTF-8');
header('Cache-Control: no-store');
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="Local plugin workspace catalogue, CLI commands, documentation, and development service health.">
    <title>Plugin Workspace | Tools &amp; Services</title>
    <style>
        :root { color-scheme: light; --ink: #17243a; --muted: #526176; --line: #dce4ed; --blue: #2459d3; --green: #147348; }
        * { box-sizing: border-box; }
        body { margin: 0; color: var(--ink); background: #f4f7fb; font: 16px/1.65 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        a { color: var(--blue); text-underline-offset: 3px; }
        a:hover { text-decoration-thickness: 2px; }
        a:focus-visible { outline: 3px solid #f1b84b; outline-offset: 4px; border-radius: 3px; }
        .container { width: min(1180px, calc(100% - 48px)); margin-inline: auto; }
        .skip-link { position: absolute; left: 24px; top: -80px; padding: 10px 18px; background: white; z-index: 2; }
        .skip-link:focus { top: 12px; }
        .hero { color: #eef4ff; background: radial-gradient(ellipse at top right, #224474, transparent 65%), #101e35; padding-bottom: 64px; }
        .nav { display: flex; justify-content: space-between; align-items: center; gap: 24px; padding-block: 24px; }
        .brand { display: flex; align-items: center; gap: 12px; font-weight: 750; letter-spacing: -.02em; }
        .brand-mark { background: #3a68e5; border-radius: 10px; padding: 5px 11px; font-family: monospace; font-size: 20px; }
        .nav-links { display: flex; flex-wrap: wrap; gap: 24px; font-size: 14px; }
        .nav a { color: #d6e3f9; text-decoration: none; }
        .eyebrow { color: #abc5ff; font-size: 12px; font-weight: 750; letter-spacing: .12em; text-transform: uppercase; }
        h1 { max-width: 780px; font-size: clamp(36px, 5vw, 58px); line-height: 1.12; letter-spacing: -.045em; margin: 20px 0; }
        .intro { color: #bfcfe5; max-width: 680px; font-size: 18px; margin-bottom: 28px; }
        .hero-summary { display: flex; flex-wrap: wrap; gap: 10px; }
        .hero-summary span { padding: 6px 14px; border: 1px solid #425674; border-radius: 999px; font-size: 13px; }
        main { padding-block: 32px 56px; }
        section { scroll-margin-top: 24px; }
        .section-heading { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: baseline; gap: 12px; margin: 32px 0 20px; }
        h2 { font-size: 25px; letter-spacing: -.025em; margin: 0; }
        .section-heading p { color: var(--muted); font-size: 14px; margin: 0; }
        .services { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
        .service, .tool, .guide, .toolchain { background: white; border: 1px solid var(--line); border-radius: 14px; }
        .service { padding: 20px 24px; min-width: 0; }
        .service-header { display: flex; justify-content: space-between; flex-wrap: wrap; gap: 8px; align-items: center; }
        .service h3 { font-size: 16px; margin: 0; }
        .service p { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; margin: 10px 0 0; }
        .status { color: var(--green); background: #e9f7ef; border-radius: 999px; padding: 3px 9px; font-size: 11px; font-weight: 750; white-space: nowrap; }
        .status.warning { color: #963d13; background: #fff0e4; }
        .tool-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 20px; }
        .tool { padding: 26px; min-width: 0; display: flex; flex-direction: column; }
        .tool-heading { display: flex; justify-content: space-between; align-items: start; gap: 12px; }
        .category { color: var(--blue); font-size: 11px; font-weight: 750; letter-spacing: .06em; text-transform: uppercase; margin: 0 0 8px; }
        .tool h3 { font-size: 23px; line-height: 1.2; letter-spacing: -.025em; margin: 0 0 6px; }
        .version { color: var(--muted); background: #f0f4f9; font: 11px/1.5 monospace; padding: 4px 7px; border-radius: 6px; white-space: nowrap; }
        .plugin-name { color: var(--muted); font: 12px/1.5 monospace; overflow-wrap: anywhere; }
        .description { font-size: 14px; color: var(--muted); margin: 18px 0; }
        .features { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 18px; }
        .features li { background: #eef3fb; border-radius: 5px; padding: 3px 8px; font-size: 11px; }
        .label { font-size: 11px; font-weight: 750; text-transform: uppercase; letter-spacing: .05em; margin: 18px 0 8px; }
        .requirements, .note, .operations { font-size: 12px; color: var(--muted); margin: 0; overflow-wrap: anywhere; }
        .operations code { display: inline-block; margin-right: 5px; font-size: 11px; }
        pre { color: #d8e8ff; background: #17263e; border-radius: 8px; padding: 13px; white-space: pre-wrap; overflow-wrap: anywhere; font: 11px/1.7 ui-monospace, SFMono-Regular, Consolas, monospace; margin: 0 0 8px; }
        .note { border-left: 2px solid #c3d3f1; padding-left: 10px; margin-top: 12px; }
        .tool-links { display: flex; flex-wrap: wrap; gap: 16px; padding-top: 22px; margin-top: auto; font-size: 13px; font-weight: 650; }
        .skills { font-size: 12px; margin: 14px 0 0; }
        .skills a { margin-right: 8px; }
        .toolchain { padding: 22px 26px; margin-top: 20px; }
        .toolchain h3 { font-size: 15px; margin: 0 0 12px; }
        .commands { list-style: none; display: flex; flex-wrap: wrap; gap: 8px; padding: 0; margin: 0; }
        .commands li { border: 1px solid #c8e5d5; color: var(--green); background: #f2faf5; border-radius: 6px; padding: 3px 10px; font: 12px/1.7 monospace; }
        .commands li.missing { border-color: #f0d2bc; color: #963d13; background: #fff5ed; }
        .toolchain p { font-size: 12px; color: var(--muted); margin: 14px 0 0; }
        .guide { padding: 28px; }
        .guide ol { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 32px; padding-left: 22px; margin: 0; }
        .guide li { padding-left: 4px; font-size: 14px; }
        .guide li::marker { color: var(--blue); font-weight: 750; }
        .guide strong { display: block; margin-bottom: 8px; }
        .guide p { margin: 0; color: var(--muted); font-size: 13px; }
        .guide code { font-size: 12px; overflow-wrap: anywhere; }
        .error { border: 1px solid #f0c7b2; background: #fff4ee; color: #963d13; border-radius: 10px; padding: 16px 20px; }
        footer { border-top: 1px solid var(--line); padding: 24px 0; color: var(--muted); font-size: 12px; }
        .footer-content { display: flex; justify-content: space-between; flex-wrap: wrap; gap: 12px; }
        @media (max-width: 1000px) { .tool-grid { grid-template-columns: 1fr; } .tool { padding: 24px; } }
        @media (max-width: 650px) {
            .container { width: calc(100% - 32px); }
            .nav { align-items: start; flex-direction: column; gap: 16px; }
            .nav-links { gap: 20px; }
            .hero { padding-bottom: 40px; }
            .services, .guide ol { grid-template-columns: 1fr; }
            .guide ol { gap: 24px; }
            .service, .guide, .toolchain { padding: 20px; }
        }
    </style>
</head>
<body>
    <a class="skip-link" href="#content">Skip to content</a>
    <header class="hero">
        <div class="container">
            <nav class="nav" aria-label="Main navigation">
                <div class="brand"><span class="brand-mark" aria-hidden="true">&gt;_</span> Plugin Workspace</div>
                <div class="nav-links">
                    <a href="#tools">Tools</a>
                    <a href="#environment">Environment</a>
                    <a href="#getting-started">Getting started</a>
                </div>
            </nav>
            <p class="eyebrow">Your local development launchpad</p>
            <h1>Every plugin.<br>One starting point.</h1>
            <p class="intro">Discover the tools in this workspace, find the right command, and check the services behind your development environment.</p>
            <div class="hero-summary">
                <?php if ($catalogueError === null): ?>
                    <span><?= html(count($plugins)) ?> workspace plugins</span>
                    <span><?= html($skillCount) ?> agent skills</span>
                <?php else: ?>
                    <span>Plugin catalogue unavailable</span>
                <?php endif; ?>
                <span>CLI + Copilot workflows</span>
            </div>
        </div>
    </header>
    <main id="content" class="container">
        <section id="environment" aria-labelledby="environment-heading">
            <div class="section-heading">
                <h2 id="environment-heading">Development environment</h2>
                <p>Web runtime and database checked on each page load.</p>
            </div>
            <div class="services">
                <article class="service">
                    <div class="service-header"><h3>Apache</h3><span class="status">Serving this page</span></div>
                    <p><?= html($_SERVER['SERVER_SOFTWARE'] ?? 'Web server version unavailable') ?> | Port 80</p>
                </article>
                <article class="service">
                    <div class="service-header"><h3>PHP</h3><span class="status">Running</span></div>
                    <p>PHP <?= html(PHP_VERSION) ?> | Xdebug <?= extension_loaded('xdebug') ? 'loaded (trigger mode)' : 'not loaded' ?></p>
                </article>
                <article class="service" data-service="mysql">
                    <div class="service-header"><h3>MySQL</h3><span class="status<?= $databaseHealth['ok'] ? '' : ' warning' ?>"><?= $databaseHealth['ok'] ? 'Connected' : 'Unavailable' ?></span></div>
                    <p><?= html($databaseHealth['detail']) ?></p>
                </article>
            </div>
            <div class="toolchain">
                <h3>Development toolchain</h3>
                <?php if ($toolchainError !== null): ?>
                    <p class="error" role="alert"><?= html($toolchainError) ?></p>
                <?php else: ?>
                    <ul class="commands" aria-label="CLI executable availability">
                        <?php foreach ($toolchain as $command => $available): ?>
                            <li<?= $available ? '' : ' class="missing"' ?>><?= html($command) ?><?= $available ? '' : ' (not detected)' ?></li>
                        <?php endforeach; ?>
                    </ul>
                <?php endif; ?>
                <p>Executable availability, not daemon health. MySQL runs in the separate <code>db</code> service; Docker-in-Docker manages its own containers. Xdebug connects to the IDE only when a debugging session is triggered.</p>
            </div>
        </section>
        <section id="tools" aria-labelledby="tools-heading">
            <div class="section-heading">
                <h2 id="tools-heading">Workspace tools</h2>
                <p>Discovered from <code>tools/*/plugin.json</code>.</p>
            </div>
            <?php if ($catalogueError !== null): ?>
                <p class="error" role="alert"><?= html($catalogueError) ?></p>
            <?php elseif ($plugins === []): ?>
                <p>No workspace plugins found. Add a plugin folder with a manifest under <code>tools/</code>.</p>
            <?php else: ?>
                <div class="tool-grid">
                    <?php foreach ($plugins as $plugin): ?>
                        <?php $details = $toolDetails[$plugin['slug']] ?? null; ?>
                        <article class="tool" data-plugin="<?= html($plugin['slug']) ?>">
                            <div class="tool-heading">
                                <div>
                                    <p class="category"><?= html($details['category'] ?? 'Workspace plugin') ?></p>
                                    <h3><?= html($details['title'] ?? $plugin['name']) ?></h3>
                                    <span class="plugin-name"><?= html($plugin['name']) ?></span>
                                </div>
                                <span class="version">v<?= html($plugin['version']) ?></span>
                            </div>
                            <p class="description"><?= html($plugin['description']) ?></p>
                            <?php if ($details !== null): ?>
                                <ul class="features">
                                    <?php foreach ($details['features'] as $feature): ?>
                                        <li><?= html($feature) ?></li>
                                    <?php endforeach; ?>
                                </ul>
                                <p class="label">Requirements</p>
                                <p class="requirements"><?= html($details['requirements']) ?></p>
                                <?php if (isset($details['operations'])): ?>
                                    <p class="label"><?= $plugin['slug'] === 'social-search' ? 'Supported networks' : 'CLI commands' ?></p>
                                    <p class="operations">
                                        <?php foreach ($details['operations'] as $operation): ?>
                                            <code><?= html($operation) ?></code>
                                        <?php endforeach; ?>
                                    </p>
                                <?php endif; ?>
                                <p class="label">Run from /workspace</p>
                                <?php foreach ($details['commands'] as $command): ?>
                                    <pre><code><?= html($command) ?></code></pre>
                                <?php endforeach; ?>
                                <p class="note"><?= html($details['note']) ?></p>
                            <?php endif; ?>
                            <div class="tool-links">
                                <?php if ($plugin['readme'] !== null): ?>
                                    <a href="<?= html($plugin['readme']) ?>">Read documentation</a>
                                <?php endif; ?>
                                <a href="<?= html($plugin['url']) ?>">Browse plugin</a>
                            </div>
                            <?php if ($plugin['skills'] !== []): ?>
                                <p class="skills">Agent skills:
                                    <?php foreach ($plugin['skills'] as $skill): ?>
                                        <a href="<?= html($skill['url']) ?>"><?= html($skill['name']) ?></a>
                                    <?php endforeach; ?>
                                </p>
                            <?php endif; ?>
                        </article>
                    <?php endforeach; ?>
                </div>
            <?php endif; ?>
        </section>
        <section id="getting-started" aria-labelledby="getting-started-heading">
            <div class="section-heading">
                <h2 id="getting-started-heading">Get started</h2>
                <p>Use a tool directly, or bring its skill into Copilot.</p>
            </div>
            <div class="guide">
                <ol>
                    <li><strong>Try the local CLI</strong><p>Open a terminal in <code>/workspace</code> and use a tool's <code>--help</code> command above. Help commands do not make external requests.</p></li>
                    <li><strong>Enable the agent plugin</strong><p>Register its folder in VS Code's <code>chat.pluginLocations</code>, then check <b>Chat: Open Customizations</b>. This catalogue lists plugins on disk, not their activation in your current chat.</p></li>
                    <li><strong>Keep research public</strong><p>Social Search sends queries to public providers. SocialCrawl needs a private API key and may consume credits. This homepage runs neither research tool.</p></li>
                </ol>
            </div>
        </section>
    </main>
    <footer>
        <div class="container footer-content">
            <span>Local development workspace | Refresh to recheck services.</span>
            <a href="/README.md">Workspace documentation</a>
        </div>
    </footer>
</body>
</html>
