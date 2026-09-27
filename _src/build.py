#!/usr/bin/env python3
"""Builds the Recortia landing page: pt-BR at /, en-US at /en/. Output: ../site/"""
import html
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
SITE = HERE.parent / 'site'
ORIGIN = 'https://mneves75.github.io/recortia/'
REPO = 'https://github.com/mneves75/recortia'
DOWNLOAD = REPO + '/releases/latest'
BREW = 'brew install --cask mneves75/tap/recortia'


def icon(name, cls='ico'):
    svg = (HERE / 'icons' / f'{name}.svg').read_text().strip()
    return svg.replace('<svg ', f'<svg class="{cls}" aria-hidden="true" focusable="false" ', 1)


T = {
    'pt-BR': dict(
        dir='', root='', other='en/', other_lang='en-US', other_label='English', other_short='EN',
        video='recortia-pt-BR.mp4', img='pt-BR',
        title='Recortia: capturas de tela que não entregam seus segredos',
        desc='App gratuito e de código aberto para macOS: capture, anote, oculte de verdade e compartilhe pela barra de menus. Tudo no seu Mac, sem conta e sem upload.',
        og_alt='Ícone do Recortia ao lado do nome, com a linha Grátis e de código aberto para macOS.',
        skip='Pular para o conteúdo',
        nav_features='Recursos', nav_privacy='Privacidade', nav_install='Instalar', nav_label='Principal',
        h1='Capturas de tela que não entregam seus segredos.',
        lede='Capture, anote, oculte e compartilhe pela barra de menus. Tudo no seu Mac, sem conta e sem upload.',
        cta='Baixar para Mac', cta2='Instalar com Homebrew',
        video_label='Vídeo de 15 segundos: um print é capturado com ⇧⌘4, recebe anotações e vira pixels; o desfoque só disfarça o texto e a tarja substitui os pixels antes de o print ser compartilhado sem metadados.',
        sound_on='Ativar som', sound_off='Desativar som',
        red_h2='A tarja troca os pixels.',
        red_p='Desfoque e pixelização são apenas estéticos: o texto pode continuar recuperável, e o próprio Recortia marca os dois como não seguros. A tarja substitui os pixels cobertos por uma cor opaca em toda cópia, arquivo salvo, arrasto e fixação.',
        chips_label='Lista de objetos do editor',
        slider='Comparar original e ocultado', before='Original', after='Ocultado pelo Recortia',
        before_alt='Janela de notas sintética com um relatório e a linha API key: sk-live-4111-1111-1111-1111 à mostra.',
        after_alt='A mesma janela exportada pelo Recortia: título desfocado, duas linhas pixelizadas e a chave coberta por uma tarja preta.',
        feat_h2='Da captura ao compartilhamento.',
        feats=[
            ('cap', 'menu', 'Capture do seu jeito', 'Região, janela ou tela inteira, com atraso ou repetindo a última região. Os atalhos padrão são os do macOS: ⇧⌘3, ⇧⌘4 e ⇧⌘5.', 'Menu do Recortia na barra de menus com as opções de captura.'),
            ('ann', 'annot', 'Anote', 'Texto, setas, retângulos, elipses, traço livre, marca-texto e passos numerados, com desfazer agrupado.', 'Captura com seta, elipse, marca-texto e passos numerados em vermelho.'),
            ('scr', 'scrollreview', 'Captura com rolagem', 'Manual por padrão. Quando a costura fica ambígua, ela pausa em vez de juntar errado.', 'Revisão de uma captura com rolagem, com a página inteira costurada.'),
            ('ocr', 'ocrpanel', 'Texto e QR code no Mac', 'Reconhecimento de texto em português e inglês com o Vision. Links de QR code só abrem quando você clica.', 'Painel Texto e QR com o texto reconhecido e os botões Copiar texto e Limpar.'),
            ('pix', 'loupe', 'Pixel a pixel', 'Lupa sem suavização, régua e conta-gotas sRGB em HEX e RGB.', 'Lupa ampliando os pixels de uma captura, com a coordenada e a cor.'),
            ('pin', 'pins', 'Fixe na tela', 'Até cinco referências flutuantes, com opacidade e zoom ajustáveis.', 'Capturas fixadas flutuando sobre a área de trabalho.'),
        ],
        priv_h2='Tudo acontece no seu Mac.',
        privs=[
            ('wifi-slash', 'Nenhuma requisição de rede', 'O Recortia não fala com servidor nenhum. Não há conta, telemetria nem nuvem.'),
            ('hand-palm', 'Nada sai sem você pedir', 'Nada é salvo ou copiado até você escolher Copiar, Salvar ou arrastar a imagem.'),
            ('file-lock', 'Exportação limpa', 'Cada imagem é codificada de novo, sem EXIF, GPS, blocos de texto nem camadas ocultas.'),
            ('shield-check', 'Permissões só quando precisa', 'Gravação de Tela na primeira captura. Acessibilidade só se você ligar a rolagem automática.'),
        ],
        priv_note='A ocultação protege a imagem que você exporta. Ela não alcança cópias exportadas antes nem o histórico de área de transferência de outros apps.',
        inst_h2='Instale com o Homebrew.',
        inst_p='Ou baixe o DMG notarizado. Requer macOS 15 ou posterior em Apple Silicon.',
        copy='Copiar', copied='Copiado', copy_label='Copiar o comando do Homebrew',
        inst_note='Para usar ⇧⌘3, ⇧⌘4 e ⇧⌘5 no Recortia, desative os atalhos do macOS em Ajustes do Sistema › Teclado › Atalhos de Teclado › Capturas de Tela. O Recortia nunca muda esses atalhos por conta própria.',
        inst_beta='Versão beta 0.9.0. Gratuito e de código aberto sob a licença MIT.',
        foot_links=[('Código no GitHub', REPO), ('Versões', REPO + '/releases'), ('Novidades', REPO + '/blob/main/CHANGELOG.md'), ('Segurança', REPO + '/blob/main/SECURITY.md'), ('Licença MIT', REPO + '/blob/main/LICENSE')],
        foot_note='Projeto independente, sem afiliação com a Apple. Mac e macOS são marcas da Apple Inc.',
        og_image='og-pt-BR.jpg', poster='poster-pt-BR.jpg', locale='pt_BR',
    ),
    'en-US': dict(
        dir='en/', root='../', other='../', other_lang='pt-BR', other_label='Português', other_short='PT',
        video='recortia-en.mp4', img='en',
        title='Recortia: screenshots that keep your secrets',
        desc='A free, open-source macOS app: capture, mark up, redact for real, and share from the menu bar. Everything stays on your Mac: no account, no upload.',
        og_alt='The Recortia icon next to its name, with the line Free and open source for macOS.',
        skip='Skip to content',
        nav_features='Features', nav_privacy='Privacy', nav_install='Install', nav_label='Main',
        h1='Screenshots that keep your secrets.',
        lede='Capture, mark up, redact, and share from the menu bar. Everything stays on your Mac: no account, no upload.',
        cta='Download for Mac', cta2='Install with Homebrew',
        video_label='15-second video: a screenshot is captured with ⇧⌘4, gets annotated, and turns into pixels; blur only disguises the text, and redaction replaces the pixels before the screenshot is shared without metadata.',
        sound_on='Sound on', sound_off='Sound off',
        red_h2='Redaction replaces the pixels.',
        red_p='Blur and pixelation are cosmetic: hidden text can remain recoverable, and Recortia itself labels both as not secure. Redaction replaces the covered pixels with an opaque color in every copy, save, drag, and pin.',
        chips_label='The editor object list',
        slider='Compare original and redacted', before='Original', after='Redacted by Recortia',
        before_alt='A synthetic notes window with a report and the line API key: sk-live-4111-1111-1111-1111 in plain view.',
        after_alt='The same window exported by Recortia: blurred title, two pixelated lines, and the key covered by a solid black bar.',
        feat_h2='From capture to share.',
        feats=[
            ('cap', 'menu', 'Capture your way', 'A region, a window, or the whole display, delayed or repeating the last region. The default shortcuts are the macOS ones: ⇧⌘3, ⇧⌘4, and ⇧⌘5.', 'The Recortia menu bar menu with the capture options.'),
            ('ann', 'annot', 'Mark up', 'Text, arrows, rectangles, ellipses, freehand, highlighter, and numbered steps, with grouped undo.', 'A capture with a red arrow, ellipse, highlight, and numbered steps.'),
            ('scr', 'scrollreview', 'Scrolling capture', 'Manual by default. When a match is ambiguous, it pauses instead of producing a wrong stitch.', 'Review of a scrolling capture with the full page stitched together.'),
            ('ocr', 'ocrpanel', 'Text and QR codes on device', 'Text recognition in English and Portuguese with Vision. QR links open only when you click.', 'The Text and QR panel with recognized text and Copy Text and Clear buttons.'),
            ('pix', 'loupe', 'Pixel by pixel', 'A nearest-neighbor loupe, a ruler, and an sRGB color picker in HEX and RGB.', 'A loupe magnifying the pixels of a capture, with the coordinate and color.'),
            ('pin', 'pins', 'Pin it', 'Up to five floating references with adjustable opacity and zoom.', 'Pinned captures floating above the desktop.'),
        ],
        priv_h2='Everything happens on your Mac.',
        privs=[
            ('wifi-slash', 'No network requests', 'Recortia talks to no server. There is no account, telemetry, or cloud.'),
            ('hand-palm', 'Nothing leaves until you ask', 'Nothing is saved or copied until you choose Copy, Save, or drag the image out.'),
            ('file-lock', 'Clean exports', 'Every image is freshly encoded, with no EXIF, GPS, text chunks, or hidden layers.'),
            ('shield-check', 'Permissions only when needed', 'Screen Recording at your first capture. Accessibility only if you turn on automatic scrolling.'),
        ],
        priv_note='Redaction protects the image you export. It cannot recall copies you exported earlier or other apps’ clipboard histories.',
        inst_h2='Install with Homebrew.',
        inst_p='Or download the notarized DMG. Requires macOS 15 or later on Apple Silicon.',
        copy='Copy', copied='Copied', copy_label='Copy the Homebrew command',
        inst_note='To use ⇧⌘3, ⇧⌘4, and ⇧⌘5 in Recortia, turn off the macOS ones in System Settings › Keyboard › Keyboard Shortcuts › Screenshots. Recortia never changes them itself.',
        inst_beta='Beta version 0.9.0. Free and open source under the MIT license.',
        foot_links=[('Code on GitHub', REPO), ('Releases', REPO + '/releases'), ('Changelog', REPO + '/blob/main/CHANGELOG.md'), ('Security', REPO + '/blob/main/SECURITY.md'), ('MIT license', REPO + '/blob/main/LICENSE')],
        foot_note='An independent project, not affiliated with Apple. Mac and macOS are trademarks of Apple Inc.',
        og_image='og-en.jpg', poster='poster-en.jpg', locale='en_US',
    ),
}


def page(lang, t):
    e = lambda s: html.escape(s, quote=True)
    r = t['root']
    url = ORIGIN + t['dir']
    feats = '\n'.join(f'''        <article class="cell cell-{k}" data-reveal>
          <div class="shot"><img src="{r}assets/img/{t['img']}/{img}.webp" alt="{e(alt)}" loading="lazy" decoding="async"></div>
          <h3>{e(h)}</h3>
          <p>{e(p)}</p>
        </article>''' for k, img, h, p, alt in t['feats'])
    privs = '\n'.join(f'''        <div class="fact" data-reveal>
          {icon(ic)}
          <h3>{e(h)}</h3>
          <p>{e(p)}</p>
        </div>''' for ic, h, p in t['privs'])
    foot = '\n'.join(f'          <li><a href="{u}">{e(n)}</a></li>' for n, u in t['foot_links'])
    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{e(t['title'])}</title>
<meta name="description" content="{e(t['desc'])}">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#131518" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
<link rel="canonical" href="{url}">
<link rel="alternate" hreflang="pt-BR" href="{ORIGIN}">
<link rel="alternate" hreflang="en-US" href="{ORIGIN}en/">
<link rel="alternate" hreflang="x-default" href="{ORIGIN}en/">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Recortia">
<meta property="og:locale" content="{t['locale']}">
<meta property="og:title" content="{e(t['title'])}">
<meta property="og:description" content="{e(t['desc'])}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{ORIGIN}assets/{t['og_image']}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{e(t['og_alt'])}">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/png" href="{r}assets/favicon.png">
<link rel="apple-touch-icon" href="{r}assets/apple-touch-icon.png">
<link rel="stylesheet" href="{r}assets/site.css">
<script src="{r}assets/site.js" defer></script>
</head>
<body>
<a class="skip" href="#conteudo">{e(t['skip'])}</a>
<header class="top">
  <nav class="wrap nav" aria-label="{e(t['nav_label'])}">
    <a class="brand" href="./" aria-label="Recortia"><img src="{r}assets/img/icon.webp" alt="" width="32" height="32">Recortia</a>
    <ul class="links">
      <li><a href="#recursos">{e(t['nav_features'])}</a></li>
      <li><a href="#privacidade">{e(t['nav_privacy'])}</a></li>
      <li><a href="#instalar">{e(t['nav_install'])}</a></li>
    </ul>
    <div class="nav-end">
      <a class="lang-switch" href="{t['other']}" hreflang="{t['other_lang']}" lang="{t['other_lang']}"><span aria-hidden="true">{t['other_short']}</span><span class="sr">{e(t['other_label'])}</span></a>
      <a class="gh" href="{REPO}">{icon('github-logo')}<span>GitHub</span></a>
    </div>
  </nav>
</header>
<main id="conteudo" tabindex="-1">
  <section class="wrap hero">
    <h1>{e(t['h1'])}</h1>
    <div class="hero-row">
    <div class="hero-copy">
      <p class="lede">{e(t['lede'])}</p>
      <div class="ctas">
        <a class="btn cta-primary" href="{DOWNLOAD}">{icon('download-simple')}{e(t['cta'])}</a>
        <a class="btn btn-ghost" href="#instalar">{e(t['cta2'])}</a>
      </div>
    </div>
    <figure class="player">
      <video playsinline loop muted controls preload="auto" poster="{r}assets/{t['poster']}" width="1920" height="1080" aria-label="{e(t['video_label'])}">
        <source src="{r}assets/{t['video']}" type="video/mp4">
      </video>
      <button class="sound" type="button" aria-pressed="false" hidden data-on="{e(t['sound_on'])}" data-off="{e(t['sound_off'])}">{icon('speaker-slash', 'ico off')}{icon('speaker-high', 'ico on')}<span>{e(t['sound_on'])}</span></button>
    </figure>
    </div>
  </section>

  <section class="wrap redact" id="tarja">
    <div class="redact-copy" data-reveal>
      <h2>{e(t['red_h2'])}</h2>
      <p>{e(t['red_p'])}</p>
      <ul class="chips" aria-label="{e(t['chips_label'])}">
        <li><img src="{r}assets/img/{t['img']}/chip-sec.webp" alt="{e('Ocultação 1: Seguro' if lang == 'pt-BR' else 'Redaction 1: Secure')}" width="220" height="28" loading="lazy"></li>
        <li><img src="{r}assets/img/{t['img']}/chip-pix.webp" alt="{e('Pixelização 1: Não seguro' if lang == 'pt-BR' else 'Pixelation 1: Not secure')}" width="220" height="28" loading="lazy"></li>
        <li><img src="{r}assets/img/{t['img']}/chip-blur.webp" alt="{e('Desfoque 1: Não seguro' if lang == 'pt-BR' else 'Blur 1: Not secure')}" width="220" height="28" loading="lazy"></li>
      </ul>
    </div>
    <figure class="compare-wrap" data-reveal>
      <div class="compare" style="--v:50%">
        <img class="compare-before" src="{r}assets/img/{t['img']}/hook-clean.webp" alt="{e(t['before_alt'])}" width="1000" height="721" loading="lazy">
        <img class="compare-after" src="{r}assets/img/{t['img']}/hook-red.webp" alt="{e(t['after_alt'])}" width="1000" height="721" loading="lazy">
        <span class="compare-handle" aria-hidden="true"></span>
        <input class="compare-range" type="range" min="0" max="100" value="50" step="1" aria-label="{e(t['slider'])}">
      </div>
      <figcaption class="compare-cap"><span>{e(t['before'])}</span><span>{e(t['after'])}</span></figcaption>
    </figure>
  </section>

  <section class="wrap features" id="recursos">
    <h2 data-reveal>{e(t['feat_h2'])}</h2>
    <div class="bento">
{feats}
    </div>
  </section>

  <section class="wrap privacy" id="privacidade">
    <h2 data-reveal>{e(t['priv_h2'])}</h2>
    <div class="facts">
{privs}
    </div>
    <p class="note" data-reveal>{e(t['priv_note'])}</p>
  </section>

  <section class="wrap install" id="instalar">
    <div class="install-panel" data-reveal>
      <h2>{e(t['inst_h2'])}</h2>
      <div class="cmd">
        <code>{BREW}</code>
        <button class="copy" type="button" aria-label="{e(t['copy_label'])}" data-copied="{e(t['copied'])}" data-copy="{e(t['copy'])}" data-cmd="{BREW}">{icon('copy', 'ico c1')}{icon('check', 'ico c2')}<span>{e(t['copy'])}</span></button>
      </div>
      <p>{e(t['inst_p'])}</p>
      <div class="ctas">
        <a class="btn cta-primary" href="{DOWNLOAD}">{icon('download-simple')}{e(t['cta'])}</a>
      </div>
      <p class="small">{e(t['inst_note'])}</p>
      <p class="small">{e(t['inst_beta'])}</p>
    </div>
  </section>
</main>
<footer class="foot">
  <div class="wrap foot-in">
    <p class="foot-brand"><img src="{r}assets/img/icon.webp" alt="" width="24" height="24">Recortia</p>
    <ul class="foot-links">
{foot}
    </ul>
    <p class="small">{e(t['foot_note'])}</p>
  </div>
</footer>
</body>
</html>
'''


for lang, t in T.items():
    out = SITE / t['dir'] / 'index.html'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page(lang, t))
    print('wrote', out.relative_to(SITE.parent))

(SITE / '.nojekyll').write_text('')
(SITE / 'robots.txt').write_text(f'User-agent: *\nAllow: /\nSitemap: {ORIGIN}sitemap.xml\n')
(SITE / 'sitemap.xml').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
  <url><loc>{ORIGIN}</loc><xhtml:link rel="alternate" hreflang="pt-BR" href="{ORIGIN}"/><xhtml:link rel="alternate" hreflang="en-US" href="{ORIGIN}en/"/></url>
  <url><loc>{ORIGIN}en/</loc><xhtml:link rel="alternate" hreflang="pt-BR" href="{ORIGIN}"/><xhtml:link rel="alternate" hreflang="en-US" href="{ORIGIN}en/"/></url>
</urlset>
''')
(SITE / '404.html').write_text(f'''<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Recortia: página não encontrada</title><link rel="stylesheet" href="/recortia/assets/site.css"></head>
<body><main class="wrap notfound"><h1>Página não encontrada.</h1><p lang="en">Page not found.</p>
<p><a class="btn cta-primary" href="/recortia/">Recortia</a> <a class="btn btn-ghost" href="/recortia/en/" lang="en">English</a></p></main></body></html>
''')
