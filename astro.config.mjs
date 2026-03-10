import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://www.karol-leszczynski.pl",
  output: "static",
  build: {
    assets: "_assets",
    inlineStylesheets: "auto",
  },
  integrations: [sitemap()],
  vite: {
    build: {
      cssMinify: true,
    },
  },
});
