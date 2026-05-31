# hron — UI design system (reference)

The canonical reference for hron's visual identity: the mark, palette, type, and
the `cron → hron` transform that anchors every screen. It documents the design the
public site (`playground/`) implements.

**This is internal — it is not part of the deployed site or the Vite build.**
Open `index.html` directly in a browser (or `python3 -m http.server` here) to view it.
Light/dark follows your system; the toggle persists a preference.

- `index.html` — the reference page (identity, palette, type, before/after)
- `styles/` — `tokens.css` (colors, type, geometry), `app.css` (chrome), `overview.css`
- `assets/` — `hron-mark.svg`, `hron-mark-dark.svg`, `hron-favicon.svg`
- `js/theme.js` — the shared light/dark toggle

The deployed implementation of these tokens lives in `playground/src/`
(`tokens.css`, `app.css`, `landing.css`, `playground.css`). Source design handoff:
Claude Design bundle `2f0DUsa2KRkZtwRI6in4LQ`.
