import { realpathSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

export const NETWORKS = Object.freeze([
  'facebook', 'twitter', 'instagram', 'tiktok', 'linkedin', 'youtube', 'reddit',
]);

export function searchUrl(query, network) {
  const url = new URL(network
    ? `https://www.social-searcher.com/${network}cse.html`
    : 'https://www.social-searcher.com/google-social-search/');
  url.searchParams.set('q', query);
  return url.href;
}

function integerOption(value, name, min, max) {
  if (!/^\d+$/.test(value) || Number(value) < min || Number(value) > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}.`);
  }
  return Number(value);
}

export function optionsFromArgs(args) {
  const { values } = parseArgs({
    args,
    options: {
      query: { type: 'string' },
      network: { type: 'string', default: 'all' },
      limit: { type: 'string', default: '5' },
      timeout: { type: 'string', default: '30000' },
      headed: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  if (values.help) return { help: true };
  if (!values.query?.trim()) throw new Error('--query must not be empty.');
  if (values.network !== 'all' && !NETWORKS.includes(values.network)) {
    throw new Error(`--network must be all or one of: ${NETWORKS.join(', ')}.`);
  }
  return {
    query: values.query.trim(),
    networks: values.network === 'all' ? [...NETWORKS] : [values.network],
    limit: integerOption(values.limit, '--limit', 1, 20),
    timeout: integerOption(values.timeout, '--timeout', 1000, 120000),
    headed: values.headed,
  };
}

export async function searchNetwork(page, { query, network, limit, timeout }) {
  const url = searchUrl(query, network);
  page.setDefaultTimeout(timeout);
  const response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
  if (!response || !response.ok()) {
    throw new Error(`${network}: search page returned HTTP ${response?.status() ?? 'unknown'}.`);
  }
  try {
    await page.waitForFunction(() => {
      const visible = (element) => element.getClientRects().length > 0;
      return [...document.querySelectorAll('.gsc-webResult .gs-title a[href]')]
        .some(visible)
        || [...document.querySelectorAll('.gs-no-results-result .gs-snippet')]
          .some(visible);
    }, undefined, { timeout });
  } catch (error) {
    if (error instanceof Error && error.name === 'TimeoutError') {
      throw new Error(`${network}: search did not render within ${timeout}ms. It may be blocked, rate-limited, or the site's layout may have changed.`);
    }
    throw error;
  }
  const results = await page.locator('.gsc-webResult').evaluateAll((elements, options) => {
    const results = [];
    const seen = new Set();
    for (const element of elements) {
      if (element.getClientRects().length === 0) continue;
      const anchor = element.querySelector('.gs-title a[href]');
      if (!anchor) continue;
      const title = anchor.textContent?.trim();
      const url = anchor.href;
      if (!title || !/^https?:\/\//i.test(url) || seen.has(url)) continue;
      seen.add(url);
      results.push({
        title,
        url,
        snippet: element.querySelector('.gs-snippet')?.textContent?.trim() ?? '',
        network: options.network,
      });
      if (results.length >= options.limit) break;
    }
    return results;
  }, { network, limit });
  if (results.length === 0) {
    const noResults = await page.locator('.gs-no-results-result .gs-snippet')
      .evaluateAll(elements => elements.some(element => element.getClientRects().length > 0));
    if (!noResults) throw new Error(`${network}: search rendered but no valid result links were found.`);
  }
  return { network, searchUrl: url, status: results.length ? 'ok' : 'no_results', results };
}

export async function search(options) {
  const browser = await chromium.launch({ headless: !options.headed });
  try {
    const page = await browser.newPage();
    const networks = [];
    for (const network of options.networks) {
      networks.push(await searchNetwork(page, { ...options, network }));
    }
    return {
      provider: 'Social Searcher',
      query: options.query,
      searchedAt: new Date().toISOString(),
      searchUrl: searchUrl(options.query),
      networks,
    };
  } finally {
    await browser.close();
  }
}

async function main() {
  try {
    const options = optionsFromArgs(process.argv.slice(2));
    if (options.help) {
      console.log('Usage: node search.mjs --query TEXT [--network all|facebook|twitter|instagram|tiktok|linkedin|youtube|reddit] [--limit 1-20] [--timeout 1000-120000] [--headed]');
      return;
    }
    console.log(JSON.stringify(await search(options), null, 2));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown search failure.';
    // Browser errors may include page content or URLs; expose only the first line.
    console.error(`Social search failed: ${message.split('\n')[0]}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  await main();
}
