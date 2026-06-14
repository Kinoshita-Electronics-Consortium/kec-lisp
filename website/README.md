# KEC Lisp docs site

Astro + [Starlight](https://starlight.astro.build) documentation site for KEC
Lisp. Built and deployed to GitHub Pages by `.github/workflows/docs.yml` (Pages
source: **GitHub Actions** — no gh-pages branch), served at
<https://kinoshita-electronics-consortium.github.io/kec-lisp/>.

## Develop

```sh
cd website
npm install
npm run dev       # http://localhost:4321/kec-lisp/
npm run build     # → website/dist/
npm run preview   # serve the built site
```

## Content is single-sourced from `../docs`

There is **no** `src/content/docs/` here. The Starlight `docs` collection is
loaded directly from the repo's top-level [`docs/`](../docs) directory via a
`glob` loader in [`src/content.config.ts`](src/content.config.ts). Edit the
Markdown in `docs/`; this site is only the shell (config, theme, assets).

Each page in `docs/` carries Starlight frontmatter (`title`, `description`); the
sidebar order is defined manually in [`astro.config.mjs`](astro.config.mjs).
Because the content lives outside this project root, Starlight's `:::note` aside
directives are not transformed — use Markdown blockquotes (`>`) for callouts.

## Why Astro is pinned to 6.1.9

`astro` and `@astrojs/starlight` are pinned to **exact** versions. Astro ≥ 6.4
deprecated the `markdown.remarkPlugins` path Starlight 0.38 uses, which produces
a noisy build and shifts Markdown processing. Bump both together and re-verify a
full `npm run build` before changing the pins.

## Theme

Amber-on-black per the `kn86-design` brand: tokens in
[`src/styles/kec.css`](src/styles/kec.css), code theme inline in
`astro.config.mjs`. Images pass through unoptimized (no `sharp` dependency).
