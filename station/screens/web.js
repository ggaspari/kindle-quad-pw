// Screenshot of the station's home page: node station/screens/web.js <url> <out.png>
// (called by capture.py, which serves the page with sample data)
const { chromium } = require('playwright');
(async () => {
  const [url, out] = process.argv.slice(2);
  const b = await chromium.launch({ args: ['--no-proxy-server'] });
  const p = await b.newPage({ viewport: { width: 600, height: 600 }, deviceScaleFactor: 2 });
  await p.goto(url);
  await p.waitForFunction(() => document.getElementById('live').textContent.includes('aviões'));
  await p.click('button');                       // shows "Copiado." with the URL selected
  await p.screenshot({ path: out, fullPage: true });
  await b.close();
})();
