import { defineConfig, passthroughImageService } from 'astro/config';
import starlight from '@astrojs/starlight';

const REPO = 'https://github.com/Kinoshita-Electronics-Consortium/kec-lisp';

// Amber-monochrome syntax theme for fenced code blocks (Expressive Code).
// Amber-on-black is the whole palette — token differentiation comes from
// brightness, not hue (warm-gray comments, bright-amber strings, etc).
// Lifted from the kn86-docs theme so the two sites read as one brand.
const kecAmberCodeTheme = {
  name: 'kec-amber',
  type: 'dark',
  colors: {
    'editor.background': '#000000',
    'editor.foreground': '#e6a020',
    'editorLineNumber.foreground': '#5a554c',
    'editorLineNumber.activeForeground': '#e6a020',
  },
  tokenColors: [
    { scope: ['comment', 'punctuation.definition.comment'], settings: { foreground: '#8f8a7d', fontStyle: 'italic' } },
    { scope: ['string', 'string.quoted', 'constant.other.symbol', 'meta.attribute-selector'], settings: { foreground: '#ffd27f' } },
    { scope: ['constant.numeric', 'constant.language', 'constant.character', 'support.constant'], settings: { foreground: '#ffd27f' } },
    { scope: ['keyword', 'keyword.control', 'storage', 'storage.type', 'storage.modifier', 'keyword.operator.logical'], settings: { foreground: '#f4b94e' } },
    { scope: ['entity.name.function', 'support.function', 'meta.function-call', 'variable.function'], settings: { foreground: '#e6a020' } },
    { scope: ['entity.name.type', 'support.type', 'support.class', 'entity.name.class', 'entity.other.inherited-class'], settings: { foreground: '#f4b94e' } },
    { scope: ['variable', 'variable.other', 'variable.parameter', 'meta.definition.variable'], settings: { foreground: '#e8e4df' } },
    { scope: ['punctuation', 'meta.brace', 'keyword.operator'], settings: { foreground: '#9c9689' } },
    { scope: ['markup.heading', 'markup.bold'], settings: { foreground: '#e6a020', fontStyle: 'bold' } },
    { scope: ['markup.inline.raw', 'markup.raw'], settings: { foreground: '#ffd27f' } },
  ],
};

export default defineConfig({
  // Default GitHub Pages project URL — served from the gh-pages branch.
  site: 'https://kinoshita-electronics-consortium.github.io',
  base: '/kec-lisp',
  // No sharp dependency — pass images through unoptimized (fine for a docs site,
  // and keeps the build free of a native module).
  image: { service: passthroughImageService() },
  // Docs content (and its images) live in ../docs, outside this project
  // root — allow Vite to read from the parent so asset imports resolve.
  vite: { server: { fs: { allow: ['..'] } } },
  integrations: [
    starlight({
      title: 'KEC Lisp',
      description: 'A small Lisp — the scripting language for the KN-86 handheld terminal. The language on its own: interpreter, standard library, and the kec CLI.',
      logo: { src: './src/assets/kec-lisp-logo.png', alt: 'KEC Lisp' },
      favicon: '/favicon.svg',
      customCss: ['./src/styles/kec.css'],
      social: [{ icon: 'github', label: 'GitHub', href: REPO }],
      editLink: { baseUrl: `${REPO}/edit/main/` },
      expressiveCode: {
        themes: [kecAmberCodeTheme],
        styleOverrides: {
          borderRadius: '0',
          borderColor: 'rgba(230, 160, 32, 0.25)',
          codeFontFamily: "'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace",
          uiFontFamily: "'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace",
          codeBackground: '#000000',
          frames: {
            editorBackground: '#000000',
            editorActiveTabBackground: '#000000',
            editorTabBarBackground: '#050505',
            terminalBackground: '#000000',
            terminalTitlebarBackground: '#050505',
            frameBoxShadowCssValue: 'none',
          },
        },
      },
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true } },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href: 'https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=Press+Start+2P&family=Space+Grotesk:wght@400;500;600;700&display=swap',
          },
        },
      ],
      sidebar: [
        {
          label: 'Start Here',
          items: [
            { label: 'Getting Started', slug: 'getting-started' },
            { label: "What's Here", slug: 'boundary' },
          ],
        },
        {
          label: 'Language',
          items: [
            { label: 'Language Reference', slug: 'language' },
            { label: 'Built-ins', slug: 'builtins' },
            { label: 'Language Standard', slug: 'language-standard' },
          ],
        },
        {
          label: 'Embedding',
          items: [{ label: 'FFI Bridge', slug: 'ffi-bridge' }],
        },
        {
          label: 'Internals',
          items: [
            { label: 'Memory Model', slug: 'memory-model' },
            { label: 'Fe Kernel — Internals', slug: 'fe-kernel' },
            { label: 'Bytecode VM (deferred)', slug: 'bytecode-vm' },
          ],
        },
        {
          label: 'Project',
          items: [
            { label: 'Changelog', link: `${REPO}/blob/main/CHANGELOG.md`, attrs: { target: '_blank' } },
            { label: 'Source (GitHub)', link: REPO, attrs: { target: '_blank' } },
          ],
        },
      ],
    }),
  ],
});
