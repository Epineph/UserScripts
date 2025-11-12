#!/usr/bin/env node
// log-net.js
// Capture all network requests/responses + HAR, with optional Chrome/Thorium/Tor.
// Usage:
//   node log-net.js [--browser=chromium|chrome|thorium] [--executable=/path/to/bin]
//                   [--tor] [--headless=false] [--ua="..."] https://target.example
//
// Requires: npm i -D playwright  && npx playwright install (and npx playwright install chrome if using channel: 'chrome')

const { chromium } = require('playwright');

function parseArgs(argv) {
  const out = { url: 'https://example.com', browser: 'chromium', headless: true, ua: null, executable: null, tor: false };
  for (const a of argv.slice(2)) {
    if (a.startsWith('--browser=')) out.browser = a.split('=')[1];
    else if (a.startsWith('--executable=')) out.executable = a.split('=')[1];
    else if (a.startsWith('--headless=')) out.headless = a.split('=')[1] !== 'false';
    else if (a === '--tor') out.tor = true;
    else if (a.startsWith('--ua=')) out.ua = a.slice('--ua='.length);
    else if (/^https?:\/\//i.test(a)) out.url = a;
  }
  return out;
}

(async () => {
  const args = parseArgs(process.argv);
  const launchOpts = { headless: args.headless, args: ['--disable-web-security'] };

  // Browser selection
  if (args.executable) {
    launchOpts.executablePath = args.executable;
  } else if (args.browser === 'chrome') {
    launchOpts.channel = 'chrome'; // requires `npx playwright install chrome`
  } else if (args.browser === 'thorium') {
    // Set a common default; allow override via --executable for other OSes.
    launchOpts.executablePath = '/usr/bin/thorium-browser';
  }

  // Tor proxy (SOCKS5)
  if (args.tor) {
    launchOpts.proxy = { server: 'socks5://127.0.0.1:9050' };
    // Reduce WebRTC leaks over Tor
    launchOpts.args.push('--force-webrtc-ip-handling-policy=disable_non_proxied_udp');
  }

  const browser = await chromium.launch(launchOpts);
  const context = await browser.newContext({
    recordHar: { path: 'site.har', content: 'embed' },
    userAgent: args.ua || undefined,
  });
  const page = await context.newPage();

  // Log requests
  page.on('request', req => {
    const post = req.postData();
    console.log('➡️ ', req.method(), req.url());
    if (post) {
      const body = typeof post === 'string' ? post : JSON.stringify(post);
      console.log('   body:', String(body).slice(0, 800));
    }
  });

  // Log responses (textual preview only)
  page.on('response', async res => {
    const url = res.url();
    const ct = res.headers()['content-type'] || '';
    let preview = '';
    try {
      if (/json|text|javascript|xml|csv/.test(ct)) {
        preview = (await res.text()).slice(0, 800);
      }
    } catch { /* non-text bodies will fail, ignore */ }
    console.log('⬅️ ', res.status(), url, ct, preview);
  });

  // Navigate and idle to catch background polling
  await page.goto(args.url, { waitUntil: 'networkidle' });
  await page.waitForTimeout(4000);

  await context.close();       // flush HAR
  await browser.close();
  console.log('HAR saved to site.har');
})().catch(e => { console.error(e); process.exit(1); });

