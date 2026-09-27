// planted control for the "every image loads" check: one good image, one missing
import { chromium } from 'playwright-core';
const exe = process.env.HOME + '/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell';
const b = await chromium.launch({ executablePath: exe }); const p = await b.newPage();
await p.goto('file:///Users/mneves/dev/PROJETOS/framepin-app/.scratch/site/404.html');
await p.evaluate(() => { for (const s of ['assets/favicon.png', 'assets/nope.webp']) { const i = new Image(); i.src = '/Users/mneves/dev/PROJETOS/framepin-app/.scratch/site/' + s; document.body.appendChild(i); } });
await p.waitForFunction(() => [...document.images].every(i => i.complete));
const broken = await p.evaluate(() => [...document.images].filter(i => !i.complete || i.naturalWidth === 0).map(i => i.getAttribute('src')));
console.log(broken.length === 1 && broken[0].endsWith('nope.webp') ? 'CONTROL OK: flagged ' + broken[0] : 'CONTROL FAILED ' + JSON.stringify(broken));
await b.close();
