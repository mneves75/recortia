// E2E for the Recortia landing page (pt-BR at /, en-US at /en/).
// usage: node e2e.mjs                 -> serves ../site under /recortia/ locally
//        BASE=https://mneves75.github.io/recortia/ node e2e.mjs   -> the live site
// Writes screenshots + report.json to ./out/<run>/ and exits non-zero on any failure.
import { chromium } from 'playwright-core';
import { createServer } from 'node:http';
import { readFileSync, existsSync, statSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, process.env.SITE_DIR || '../site');
const run = new Date().toISOString().replace(/[:.]/g, '-');
const OUT = path.join(here, 'out', process.env.BASE ? 'live-' + run : run);
mkdirSync(OUT, { recursive: true });

// ---- the contract the page must meet
const SPEC = {
  'pt-BR': {
    path: '', h1: 'Capturas de tela que não entregam seus segredos.', other: 'en/', otherLang: 'en-US',
    video: 'assets/recortia-pt-BR.mp4', copied: 'Copiado', slider: 'Comparar original e ocultado',
  },
  'en-US': {
    path: 'en/', h1: 'Screenshots that keep your secrets.', other: '../', otherLang: 'pt-BR',
    video: '../assets/recortia-en.mp4', copied: 'Copied', slider: 'Compare original and redacted',
  },
};
const DOWNLOAD = 'https://github.com/mneves75/recortia/releases/latest';

// ---- local server (mimics GitHub Pages project path)
let server, BASE = process.env.BASE;
if (!BASE) {
  const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mp4': 'video/mp4', '.webp': 'image/webp', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.txt': 'text/plain', '.xml': 'application/xml' };
  server = createServer((req, res) => {
    let u = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (!u.startsWith('/recortia/')) { res.writeHead(404); return res.end('nf'); }
    let p = path.join(SITE, u.slice('/recortia/'.length));
    if (!p.startsWith(SITE)) { res.writeHead(403); return res.end(); }
    if (existsSync(p) && statSync(p).isDirectory()) p = path.join(p, 'index.html');
    if (!existsSync(p)) { res.writeHead(404); return res.end('nf'); }
    const buf = readFileSync(p), type = types[path.extname(p)] || 'application/octet-stream';
    const range = req.headers.range;   // videos need byte ranges to report duration
    if (range) {
      const [a, b] = range.replace('bytes=', '').split('-'); const s = Number(a), e = b ? Number(b) : buf.length - 1;
      res.writeHead(206, { 'content-type': type, 'content-range': `bytes ${s}-${e}/${buf.length}`, 'accept-ranges': 'bytes', 'content-length': e - s + 1 });
      return res.end(buf.subarray(s, e + 1));
    }
    res.writeHead(200, { 'content-type': type, 'accept-ranges': 'bytes', 'content-length': buf.length }); res.end(buf);
  }).listen(0, '127.0.0.1');
  await new Promise(r => server.once('listening', r));
  BASE = `http://127.0.0.1:${server.address().port}/recortia/`;
}

const results = []; let failed = 0;
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail: String(detail).slice(0, 400) }); if (!ok) { failed++; console.log('FAIL', name, detail); } else console.log('ok  ', name); };

const exe = `${process.env.HOME}/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell`;
const browser = await chromium.launch({ executablePath: exe, args: ['--autoplay-policy=no-user-gesture-required'] });
const axeSrc = readFileSync(path.join(here, 'node_modules/axe-core/axe.min.js'), 'utf8');

// non-waiting DOM reads: a missing element is a failed check, not a 30 s stall
const q = (page, sel, fn) => page.evaluate(([sel, fn]) => { const e = document.querySelector(sel); return e ? new Function('e', 'return ' + fn)(e) : null; }, [sel, fn]);
const attr = (page, sel, a) => q(page, sel, 'e.getAttribute(' + JSON.stringify(a) + ')');
// walk the page so lazy images load; returns the images that failed to decode, then scrolls back up
async function walk(page) {
  for (let y = 0; y < await page.evaluate(() => document.body.scrollHeight); y += 600) { await page.evaluate(y => window.scrollTo(0, y), y); await page.waitForTimeout(60); }
  await page.waitForFunction(() => [...document.images].every(i => i.complete), null, { timeout: 8000 }).catch(() => {});
  const broken = await page.evaluate(() => [...document.images].filter(i => !i.complete || i.naturalWidth === 0).map(i => i.getAttribute('src')));
  await page.evaluate(() => window.scrollTo(0, 0));
  return broken;
}
async function axe(page) {
  await page.addScriptTag({ content: axeSrc });
  return page.evaluate(async () => {
    const r = await window.axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'] } });
    return r.violations.map(v => ({ id: v.id, impact: v.impact, n: v.nodes.length, target: v.nodes.slice(0, 3).map(n => n.target.join(' ')) }));
  });
}

// planted control: axe must flag a known contrast failure, or its silence means nothing
{
  const ctx = await browser.newContext(); const page = await ctx.newPage();
  await page.setContent('<html lang="en"><head><title>c</title></head><body style="background:#fff"><main><p style="color:#ddd">low contrast</p></main></body></html>');
  const v = await axe(page);
  check('control: axe flags planted low contrast', v.some(x => x.id === 'color-contrast'), JSON.stringify(v));
  await ctx.close();
}

for (const [lang, S] of Object.entries(SPEC)) {
  const url = BASE + S.path;
  for (const scheme of ['dark', 'light']) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: scheme, permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await ctx.newPage();
    const errors = [], bad = [];
    page.on('pageerror', e => errors.push(e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('response', r => { if (r.status() >= 400) bad.push(r.status() + ' ' + r.url()); });
    const resp = await page.goto(url, { waitUntil: 'load' });
    const tag = `${lang}/${scheme}`;
    check(`${tag}: 200`, resp.status() === 200, resp.status());
    if (scheme === 'dark') try {
      check(`${tag}: html lang`, await attr(page, 'html', 'lang') === lang);
      const title = await page.title(); check(`${tag}: title`, /Recortia/.test(title), title);
      check(`${tag}: meta description`, (await attr(page, 'meta[name=description]', 'content') || '').length > 50);
      const alts = await page.$$eval('link[rel=alternate][hreflang]', ls => ls.map(l => l.hreflang + '=' + l.href));
      check(`${tag}: hreflang pt-BR, en-US, x-default`, ['pt-BR', 'en-US', 'x-default'].every(h => alts.some(a => a.startsWith(h + '='))), alts.join(' '));
      check(`${tag}: canonical`, !!(await page.$('link[rel=canonical]')));
      check(`${tag}: og:image`, !!(await attr(page, 'meta[property="og:image"]', 'content')));
      const h1 = (await q(page, 'h1', 'e.textContent') || '').replace(/\s+/g, ' ').trim();
      check(`${tag}: h1 copy`, h1 === S.h1, h1);
      const cta = await page.$$eval('a.cta-primary', as => as.map(a => a.href));
      check(`${tag}: download CTA -> releases/latest`, cta.length >= 1 && cta.every(h => h === DOWNLOAD), cta.join(' '));
      const txt = await page.evaluate(() => document.body.innerText);
      check(`${tag}: no em or en dashes in visible text`, !/[—–]/.test(txt), (txt.match(/.{0,30}[—–].{0,30}/) || [''])[0]);
      // video
      const vsrc = await attr(page, 'video source', 'src');
      check(`${tag}: video source`, vsrc === S.video, vsrc);
      const dur = await page.$eval('video', v => new Promise(res => { if (v.readyState >= 1) return res(v.duration); v.addEventListener('loadedmetadata', () => res(v.duration), { once: true }); setTimeout(() => res(-1), 8000); }));
      check(`${tag}: video plays 15 s`, dur > 14.8 && dur < 15.2, dur);
      const playing = await page.waitForFunction(() => { const v = document.querySelector('video'); return v && !v.paused && v.currentTime > 0.2; }, null, { timeout: 8000 }).then(() => true, () => false);
      check(`${tag}: video autoplays muted`, playing && await page.$eval('video', v => v.muted));
      await page.click('button.sound');
      check(`${tag}: sound toggle unmutes`, await page.$eval('video', v => !v.muted) && await attr(page, 'button.sound', 'aria-pressed') === 'true');
      // language switch
      const sw = await page.$eval('a.lang-switch', a => ({ href: a.getAttribute('href'), hreflang: a.getAttribute('hreflang') }));
      check(`${tag}: language switch`, sw.href === S.other && sw.hreflang === S.otherLang, JSON.stringify(sw));
      // redaction comparison
      const slider = page.getByRole('slider', { name: S.slider });
      check(`${tag}: comparison slider has accessible name`, await slider.count() === 1);
      await slider.focus(); await slider.fill('20');
      const clip = await page.$eval('.compare-after', e => getComputedStyle(e).clipPath);
      check(`${tag}: slider moves the reveal`, /20%/.test(clip), clip);
      await page.keyboard.press('ArrowRight');
      check(`${tag}: slider responds to keyboard`, await slider.inputValue() !== '20', await slider.inputValue());
      // copy the install command
      await page.click('button.copy');
      await page.waitForFunction(t => document.querySelector('button.copy')?.textContent.includes(t), S.copied, { timeout: 2000 }).catch(() => {});
      const label = await page.textContent('button.copy');
      const clipText = await page.evaluate(() => navigator.clipboard.readText()).catch(e => 'ERR ' + e.message);
      check(`${tag}: copy button feedback`, (label || '').includes(S.copied), label);
      check(`${tag}: copied brew command`, clipText === 'brew install --cask mneves75/tap/recortia', clipText);
      // keyboard focus is visible on the primary CTA
      // reach the CTA the way a keyboard user does: fresh load, then Tab
      await page.goto(url, { waitUntil: 'load' });
      for (let k = 0; k < 15 && !(await page.evaluate(() => document.activeElement?.matches('a.cta-primary'))); k++) await page.keyboard.press('Tab');
      check(`${tag}: CTA reachable by Tab`, await page.evaluate(() => document.activeElement?.matches('a.cta-primary')));
      const ring = await page.$eval('a.cta-primary', a => { const s = getComputedStyle(a); return s.outlineStyle + ' ' + s.outlineWidth; });
      check(`${tag}: visible focus ring`, !/^none/.test(ring) && !/ 0px$/.test(ring), ring);
      const skip = await page.$('a.skip');
      check(`${tag}: skip link`, !!skip);
    } catch (e) { check(`${tag}: page interactions`, false, e.message.split('\n')[0]); }
    // nav on one line
    const navH = await q(page, 'header nav', 'e.getBoundingClientRect().height') ?? 999;
    check(`${tag}: nav height <= 80`, navH <= 80, navH);
    // accessibility in this theme (reveal everything first)
    await page.emulateMedia({ reducedMotion: 'reduce', colorScheme: scheme });
    const broken = await walk(page);
    check(`${tag}: every image loads`, broken.length === 0, broken.join(' '));
    const v = await axe(page);
    check(`${tag}: axe WCAG 2.2 AA`, v.length === 0, JSON.stringify(v));
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: path.join(OUT, `${lang}-${scheme}-1440.png`), fullPage: true });
    await page.screenshot({ path: path.join(OUT, `${lang}-${scheme}-1440-fold.png`) });
    check(`${tag}: no console errors`, errors.length === 0, errors.join(' | '));
    check(`${tag}: no failed requests`, bad.length === 0, bad.join(' | '));
    await ctx.close();
  }
  // widths: no horizontal scroll, screenshots
  for (const w of [1024, 768, 400]) {
    for (const scheme of ['dark', 'light']) {
      if (w !== 400 && scheme === 'light') continue;
      const ctx = await browser.newContext({ viewport: { width: w, height: 860 }, colorScheme: scheme, reducedMotion: 'reduce' });
      const page = await ctx.newPage(); await page.goto(url, { waitUntil: 'load' });
      const m = await page.evaluate(() => ({ iw: innerWidth, sw: document.scrollingElement.scrollWidth }));
      check(`${lang} ${w}px ${scheme}: viewport honored`, m.iw === w, JSON.stringify(m));
      check(`${lang} ${w}px ${scheme}: no horizontal scroll`, m.sw <= m.iw, JSON.stringify(m));
      if (w === 400) {
        const navH = await q(page, 'header nav', 'e.getBoundingClientRect().height') ?? 999;
        check(`${lang} 400px: nav fits`, navH <= 80, navH);
        const vid = await q(page, 'video', '({ paused: e.paused, controls: e.controls })') ?? { paused: null };
        check(`${lang} reduced motion: video does not autoplay`, vid.paused === true, JSON.stringify(vid));
      }
      const broken = await walk(page);
      check(`${lang} ${w}px ${scheme}: every image loads`, broken.length === 0, broken.join(' '));
      await page.screenshot({ path: path.join(OUT, `${lang}-${scheme}-${w}.png`), fullPage: true });
      await ctx.close();
    }
  }
}
await browser.close(); server?.close();
writeFileSync(path.join(OUT, 'report.json'), JSON.stringify({ base: BASE, run, failed, total: results.length, results }, null, 2));
console.log(`\n${results.length - failed}/${results.length} passed -> ${OUT}`);
process.exit(failed ? 1 : 0);
