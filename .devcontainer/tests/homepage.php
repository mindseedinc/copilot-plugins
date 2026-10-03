<?php
declare(strict_types=1);

$workspace = dirname(__DIR__, 2);
ob_start();
require $workspace . '/index.php';
$rendered = ob_get_clean();
if ($rendered === false) {
    throw new RuntimeException('The homepage render could not be captured.');
}

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function expectFailure(callable $callback, string $expectedClass): void
{
    try {
        $callback();
    } catch (JsonException | RuntimeException $error) {
        check($error instanceof $expectedClass, 'The failure must have the expected exception type.');
        return;
    }
    throw new RuntimeException('Invalid input must fail explicitly.');
}

$plugins = workspacePlugins($workspace . '/tools');
check(count($plugins) > 0, 'The workspace must contain plugins.');
check(substr_count($rendered, 'data-plugin="') === count($plugins), 'Every discovered plugin must have exactly one rendered card.');
foreach ($plugins as $plugin) {
    check(str_contains($rendered, 'data-plugin="' . html($plugin['slug']) . '"'), 'A discovered plugin is missing from the page.');
    check(str_contains($rendered, html($plugin['name'])), 'The manifest name must be visible.');
    check(str_contains($rendered, html($plugin['description'])), 'The manifest description must be visible.');
    foreach ($plugin['skills'] as $skill) {
        check(str_contains($rendered, 'href="' . html($skill['url']) . '"'), 'Every discovered skill must have a link.');
    }
}
check(str_contains($rendered, '<title>Plugin Workspace | Tools &amp; Services</title>'), 'The page must have its own title.');
check(html('<script>"test"&</script>') === '&lt;script&gt;&quot;test&quot;&amp;&lt;/script&gt;', 'HTML content must be escaped.');
check(workspaceCommandAvailable('php'), 'PHP must be detected in PATH.');
check(!workspaceCommandAvailable('workspace-homepage-nonexistent-command'), 'Missing commands must not be marked available.');

$originalPort = getenv('DB_PORT');
try {
    check(putenv('DB_PORT=invalid'), 'The invalid database configuration must be set.');
    $invalidDatabase = workspaceDatabaseHealth();
    check($invalidDatabase['ok'] === false, 'Invalid database settings must not be marked healthy.');
    check(str_contains($invalidDatabase['detail'], 'DB_*'), 'Invalid database settings must have an actionable error.');
} finally {
    check(putenv($originalPort === false ? 'DB_PORT' : 'DB_PORT=' . $originalPort), 'The database configuration must be restored.');
}

$fixture = sys_get_temp_dir() . '/workspace-homepage-' . bin2hex(random_bytes(8));
$pluginDirectory = $fixture . '/example plugin';
$skillDirectory = $pluginDirectory . '/skills/example skill';
check(mkdir($fixture, 0700), 'The fixture directory must be created.');
try {
    check(workspacePlugins($fixture) === [], 'An empty tools directory must have no plugins.');
    check(mkdir($skillDirectory, 0700, true), 'The fixture skill directory must be created.');
    $manifest = ['name' => 'Example <plugin>', 'version' => '1.0.0', 'description' => 'A test & fixture'];
    check(file_put_contents($pluginDirectory . '/plugin.json', json_encode($manifest, JSON_THROW_ON_ERROR)) !== false, 'The fixture manifest must be written.');
    check(file_put_contents($skillDirectory . '/SKILL.md', '# Example') !== false, 'The fixture skill must be written.');
    $discovered = workspacePlugins($fixture);
    check(count($discovered) === 1, 'New plugin folders must be discovered automatically.');
    check($discovered[0]['readme'] === null, 'Absent documentation must not produce a broken link.');
    check($discovered[0]['url'] === '/tools/example%20plugin/', 'Plugin URLs must encode path segments.');
    check($discovered[0]['skills'][0]['url'] === '/tools/example%20plugin/skills/example%20skill/SKILL.md', 'Skill URLs must encode path segments.');

    check(file_put_contents($pluginDirectory . '/plugin.json', '{invalid') !== false, 'The invalid JSON fixture must be written.');
    expectFailure(static fn () => workspacePlugins($fixture), JsonException::class);
    check(file_put_contents($pluginDirectory . '/plugin.json', '{"name":"Incomplete"}') !== false, 'The incomplete manifest fixture must be written.');
    expectFailure(static fn () => workspacePlugins($fixture), RuntimeException::class);
    expectFailure(static fn () => workspacePlugins($fixture . '/missing'), RuntimeException::class);
} finally {
    foreach ([$skillDirectory . '/SKILL.md', $pluginDirectory . '/plugin.json'] as $file) {
        if (is_file($file)) {
            check(unlink($file), 'The fixture file must be removed.');
        }
    }
    foreach ([$skillDirectory, $pluginDirectory . '/skills', $pluginDirectory, $fixture] as $directory) {
        if (is_dir($directory)) {
            check(rmdir($directory), 'The fixture directory must be removed.');
        }
    }
}

echo "Homepage tests passed: plugin discovery, complete rendering, escaping, URL encoding, invalid database settings, and failure handling.\n";
