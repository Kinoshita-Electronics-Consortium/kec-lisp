import { defineCollection } from 'astro:content';
import { docsSchema } from '@astrojs/starlight/schema';
import { glob } from 'astro/loaders';

// Single source of truth: the docs collection is loaded from the repo's
// top-level docs/ directory (../docs), not from website/src/content/docs.
// All language documentation lives in docs/ and is read directly here.
export const collections = {
  docs: defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: '../docs' }),
    schema: docsSchema(),
  }),
};
