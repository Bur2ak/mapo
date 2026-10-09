# Mapo website

Static, no build step: `index.html` + `images/`. Deploy to Cloudflare Pages:

```sh
npx wrangler pages deploy site --project-name mapo
```

Refresh the screenshots from `docs/images/` when the app changes.
