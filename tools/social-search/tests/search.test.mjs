import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test, before, after } from 'node:test';
import { chromium } from 'playwright';
import { optionsFromArgs, searchNetwork, searchUrl } from '../skills/social-search/scripts/search.mjs';

test('manifest declares Agent Plugins 1.0 and skill exists', async () => {
  const manifest = JSON.parse(await readFile(new URL('../plugin.json', import.meta.url)));
  assert.equal(manifest.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
  assert.equal(manifest.name, 'social-search');
  const skill = await readFile(new URL('../skills/social-search/SKILL.md', import.meta.url), 'utf8');
  assert.match(skill, /^---\nname: social-search\n/);
});

test('query is encoded without adding URL parameters', () => {
  const url = new URL(searchUrl('#copilot & "VS Code" OR agents', 'reddit'));
  assert.equal(url.origin, 'https://www.social-searcher.com');
  assert.equal(url.pathname, '/redditcse.html');
  assert.equal(url.searchParams.get('q'), '#copilot & "VS Code" OR agents');
  assert.equal([...url.searchParams].length, 1);
});

test('options enforce query, network, and numeric bounds', () => {
  assert.equal(optionsFromArgs(['--query', ' test ']).query, 'test');
  assert.equal(optionsFromArgs(['--query', 'test']).networks.length, 7);
  for (const args of [
    [], ['--query', ' '], ['--query', 'x', '--network', 'invalid'],
    ['--query', 'x', '--limit', '0'], ['--query', 'x', '--limit', '21'],
    ['--query', 'x', '--limit', '1.5'], ['--query', 'x', '--timeout', '999'],
    ['--query', 'x', '--timeout', '120001'], ['--query', 'x', '--unknown'],
  ]) assert.throws(() => optionsFromArgs(args));
  assert.equal(optionsFromArgs(['--help']).help, true);
});

let browser;
before(async () => { browser = await chromium.launch(); });
after(async () => { await browser?.close(); });

async function fixture(body, run, status = 200) {
  const page = await browser.newPage();
  try {
    await page.route('**/*', route => route.fulfill({
      status, contentType: 'text/html', body,
    }));
    return await run(page);
  } finally {
    await page.close();
  }
}

const options = { query: 'copilot', network: 'reddit', limit: 2, timeout: 1000 };
const result = (title, url, snippet) =>
  `<div class="gsc-webResult"><div class="gs-title"><a href="${url}">${title}</a></div><div class="gs-snippet">${snippet}</div></div>`;

test('extracts title, URL, snippet, deduplicates and enforces limit', async () => {
  const html = result('First', 'https://reddit.com/1', 'A &amp; B')
    + result('Duplicate', 'https://reddit.com/1', 'Duplicate')
    + `<div style="display:none">${result('Hidden', 'https://reddit.com/hidden', 'Hidden')}</div>`
    + result('Second', 'https://reddit.com/2', 'Second excerpt')
    + result('Third', 'https://reddit.com/3', 'Third excerpt');
  await fixture(html, async page => {
    const output = await searchNetwork(page, options);
    assert.equal(output.status, 'ok');
    assert.deepEqual(output.results, [
      { title: 'First', url: 'https://reddit.com/1', snippet: 'A & B', network: 'reddit' },
      { title: 'Second', url: 'https://reddit.com/2', snippet: 'Second excerpt', network: 'reddit' },
    ]);
  });
});

test('reports explicit no-results state', async () => {
  await fixture('<div class="gs-no-results-result"><div class="gs-snippet">No results</div></div>', async page => {
    const output = await searchNetwork(page, options);
    assert.equal(output.status, 'no_results');
    assert.deepEqual(output.results, []);
  });
});

test('HTTP failures are not empty successful searches', async () => {
  await fixture('Rate limited', page =>
    assert.rejects(searchNetwork(page, options), /HTTP 429/), 429);
});

test('layout changes or blocked searches fail explicitly', async () => {
  await fixture('<p>Verification required</p>', page =>
    assert.rejects(searchNetwork(page, options), /search did not render/));
});

test('invalid result links do not become a no-results success', async () => {
  await fixture(result('Invalid', 'javascript:void(0)', 'Bad link'), page =>
    assert.rejects(searchNetwork(page, options), /no valid result links/));
});
