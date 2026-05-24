import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://www.karol-leszczynski.pl",
  output: "static",
  build: {
    assets: "_assets",
    inlineStylesheets: "auto",
  },
  integrations: [
    sitemap({
      changefreq: "weekly",
      priority: 0.7,
      lastmod: new Date(),
      serialize(item) {
        const url = item.url;
        if (url === "https://www.karol-leszczynski.pl/") {
          return { ...item, changefreq: "weekly", priority: 1.0 };
        }
        if (url.includes("/blog/") && url !== "https://www.karol-leszczynski.pl/blog/") {
          return { ...item, changefreq: "monthly", priority: 0.8 };
        }
        if (url === "https://www.karol-leszczynski.pl/blog/") {
          return { ...item, changefreq: "daily", priority: 0.9 };
        }
        if (url.includes("/uslugi/")) {
          return { ...item, changefreq: "monthly", priority: 0.9 };
        }
        if (url.includes("/projekty")) {
          return { ...item, changefreq: "monthly", priority: 0.8 };
        }
        if (url.includes("/kontakt")) {
          return { ...item, changefreq: "yearly", priority: 0.6 };
        }
        if (url.includes("/polityka")) {
          return { ...item, changefreq: "yearly", priority: 0.2 };
        }
        return item;
      },
    }),
  ],
  vite: {
    build: {
      cssMinify: true,
    },
  },
});
