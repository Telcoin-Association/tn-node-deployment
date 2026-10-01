# Vendored assets for the partner guide

These files are fetched once and committed so the PDF build works offline and gives the
same output on every run. Nothing here is downloaded at build time.

- **Fonts** are Geist and Geist Mono by Vercel, licensed under the SIL Open Font
  License 1.1. Both licence files from the upstream tag are kept beside the fonts
  (`OFL.txt` carries the current copyright line, `LICENSE.txt` the original one).
- **Logos** are Telcoin Association brand assets, used with permission for this guide.
  They are plain SVG (`<path>` elements and one `<clipPath>`; no text, fonts or external
  references), so they render as vectors with no font dependency.

Retrieved 2026-10-01. Fonts come from the `v1.7.2` tag of
[vercel/geist-font](https://github.com/vercel/geist-font), commit
`a73329da8fc62afc917f796555202e4997f79b7c`. The fonts are the static per-weight
`.woff2` files, not the variable font, so `font-weight` maps to a real face.

| File | Source URL | Tag / commit | Retrieved | Licence | Bytes |
|---|---|---|---|---|---|
| `fonts/Geist-Regular.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Regular.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 45228 |
| `fonts/Geist-Italic.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Italic.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46888 |
| `fonts/Geist-Medium.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Medium.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46464 |
| `fonts/Geist-SemiBold.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-SemiBold.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46304 |
| `fonts/Geist-Bold.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Bold.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46668 |
| `fonts/GeistMono-Regular.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/GeistMono/webfonts/GeistMono-Regular.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 50764 |
| `fonts/GeistMono-SemiBold.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/GeistMono/webfonts/GeistMono-SemiBold.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 51844 |
| `fonts/OFL.txt` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/OFL.txt | v1.7.2 | 2026-10-01 | OFL 1.1 (licence text) | 4383 |
| `fonts/LICENSE.txt` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/LICENSE.txt | v1.7.2 | 2026-10-01 | OFL 1.1 (licence text) | 4368 |
| `logos/telcoin-network-light.svg` | https://tel3.telcoin.network/images/logos/telcoin-network-light.svg | n/a (live site) | 2026-10-01 | Telcoin Association brand asset, used with permission | 16195 |
| `logos/telcoin-association-white.svg` | https://tel3.telcoin.network/images/logos/telcoin-association-white.svg | n/a (live site) | 2026-10-01 | Telcoin Association brand asset, used with permission | 20215 |

Logo view boxes: `telcoin-network-light.svg` is `0 0 262 41`, `telcoin-association-white.svg`
is `0 0 272 36`. Both are a white wordmark with a `#14C8FF` mark, drawn for a dark
background, which is why they appear only on the navy cover.

To refresh a file, fetch it again from the URL above, check it is the right type
(`file` should report "Web Open Font Format" or "SVG"), and update the size and date in
this table in the same commit.
