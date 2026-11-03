# Vendored assets for the partner documents

Both partner documents use these files: the MNO node guide and the Telcoin Network
Technical Specification. They are fetched once and committed so each PDF build works
offline and gives the same output on every run. Nothing here is downloaded at build time.

- **Fonts.** The node guide is set in Geist and Geist Mono by Vercel, under
  `fonts/geist/`. Both licence files from the upstream tag are kept beside them
  (`OFL.txt` carries the current copyright line, `LICENSE.txt` the original one). The
  specification is set in Inter by Rasmus Andersson, under `fonts/inter/`: six static
  faces, with the upstream `LICENSE.txt` beside them. Code spans in the specification use
  Geist Mono from `fonts/geist/`. Both families are licensed under the SIL Open Font
  License 1.1.
- **Logos** are Telcoin Association brand assets, used with permission for these
  documents. They are plain SVG (`<path>` elements and one `<clipPath>`; no text, fonts or
  external references), so they render as vectors with no font dependency. The two white
  wordmarks are for dark backgrounds and the two `-dark` wordmarks for light ones (see
  below).
- **Covers.** `covers/technical-specification.png` is the full-page artwork behind the
  specification's cover (see below).

Geist was retrieved 2026-10-01 from the `v1.7.2` tag of
[vercel/geist-font](https://github.com/vercel/geist-font), commit
`a73329da8fc62afc917f796555202e4997f79b7c`. Inter was retrieved 2026-10-15 from the
`v4.1` tag of [rsms/inter](https://github.com/rsms/inter), commit
`e3a3d4c57d5ecc01453a575621882a384c1995a3`, directory `docs/font-files/`. Both are the
static per-weight `.woff2` files, not the variable font, so `font-weight` maps to a real
face.

| File | Source URL | Tag / commit | Retrieved | Licence | Bytes |
|---|---|---|---|---|---|
| `fonts/geist/Geist-Regular.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Regular.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 45228 |
| `fonts/geist/Geist-Italic.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Italic.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46888 |
| `fonts/geist/Geist-Medium.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Medium.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46464 |
| `fonts/geist/Geist-SemiBold.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-SemiBold.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46304 |
| `fonts/geist/Geist-Bold.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/webfonts/Geist-Bold.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 46668 |
| `fonts/geist/GeistMono-Regular.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/GeistMono/webfonts/GeistMono-Regular.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 50764 |
| `fonts/geist/GeistMono-SemiBold.woff2` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/GeistMono/webfonts/GeistMono-SemiBold.woff2 | v1.7.2 | 2026-10-01 | OFL 1.1 | 51844 |
| `fonts/geist/OFL.txt` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/OFL.txt | v1.7.2 | 2026-10-01 | OFL 1.1 (licence text) | 4383 |
| `fonts/geist/LICENSE.txt` | https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/LICENSE.txt | v1.7.2 | 2026-10-01 | OFL 1.1 (licence text) | 4368 |
| `fonts/inter/Inter-Regular.woff2` | https://raw.githubusercontent.com/rsms/inter/v4.1/docs/font-files/Inter-Regular.woff2 | v4.1 | 2026-10-15 | OFL 1.1 | 111268 |
| `fonts/inter/Inter-Italic.woff2` | https://raw.githubusercontent.com/rsms/inter/v4.1/docs/font-files/Inter-Italic.woff2 | v4.1 | 2026-10-15 | OFL 1.1 | 117700 |
| `fonts/inter/Inter-Medium.woff2` | https://raw.githubusercontent.com/rsms/inter/v4.1/docs/font-files/Inter-Medium.woff2 | v4.1 | 2026-10-15 | OFL 1.1 | 114348 |
| `fonts/inter/Inter-SemiBold.woff2` | https://raw.githubusercontent.com/rsms/inter/v4.1/docs/font-files/Inter-SemiBold.woff2 | v4.1 | 2026-10-15 | OFL 1.1 | 114812 |
| `fonts/inter/Inter-Bold.woff2` | https://raw.githubusercontent.com/rsms/inter/v4.1/docs/font-files/Inter-Bold.woff2 | v4.1 | 2026-10-15 | OFL 1.1 | 114840 |
| `fonts/inter/Inter-BoldItalic.woff2` | https://raw.githubusercontent.com/rsms/inter/v4.1/docs/font-files/Inter-BoldItalic.woff2 | v4.1 | 2026-10-15 | OFL 1.1 | 121500 |
| `fonts/inter/LICENSE.txt` | https://raw.githubusercontent.com/rsms/inter/v4.1/LICENSE.txt | v4.1 | 2026-10-15 | OFL 1.1 (licence text) | 4380 |
| `logos/telcoin-network-light.svg` | https://tel3.telcoin.network/images/logos/telcoin-network-light.svg | n/a (live site) | 2026-10-01 | Telcoin Association brand asset, used with permission | 16195 |
| `logos/telcoin-association-white.svg` | https://tel3.telcoin.network/images/logos/telcoin-association-white.svg | n/a (live site) | 2026-10-01 | Telcoin Association brand asset, used with permission | 20215 |
| `logos/telcoin-network-dark.svg` | https://github.com/Telcoin-Association/telcoin-network/blob/v0.16.0-adiri/docs/src/assets/tn-light.svg | v0.16.0-adiri | 2026-10-15 | Telcoin Association brand asset, used with permission | 16189 |
| `logos/telcoin-association-dark.svg` | derived from `logos/telcoin-association-white.svg` | n/a (recoloured here) | 2026-10-15 | Telcoin Association brand asset, used with permission | 20257 |
| `covers/technical-specification.png` | April 2026 Google Docs export of the specification (not a URL) | n/a | 2026-10-15 | Telcoin Association brand asset, used with permission | 879172 |

Logo view boxes: `telcoin-network-light.svg` is `0 0 262 41`, `telcoin-network-dark.svg`
is `0 0 2613 400`, and both association files are `0 0 272 36`. Every file pairs a
wordmark with the `#14C8FF` mark, and the "t" inside the mark is white in all four. The
file names follow the wordmark colour:

- `telcoin-network-light.svg` and `telcoin-association-white.svg` draw the wordmark in
  white for a dark background, which is why the node guide uses them only on its navy
  cover.
- `telcoin-network-dark.svg` and `telcoin-association-dark.svg` draw the wordmark in
  `#424761` for a light background. The technical specification uses them on its light
  cover and in its footer.

`telcoin-network-dark.svg` is a byte-for-byte copy of `docs/src/assets/tn-light.svg` in
the telcoin-network repository at tag `v0.16.0-adiri`, commit
`d72cc2bcfceb2e61b968915d72dc7e3761dd7e0b`. Upstream names it for the light theme it
serves. Fetch it from
https://raw.githubusercontent.com/Telcoin-Association/telcoin-network/v0.16.0-adiri/docs/src/assets/tn-light.svg.

`telcoin-association-dark.svg` is a derived recolour of the white brand asset, made here
on 2026-10-15 for the light cover and footer of the technical specification. It changes
the 21 wordmark paths from `fill="white"` to `fill="#424761"`, the wordmark colour of the
network logo above, and nothing else. Two `fill="white"` attributes stay as they are: the
"t" inside the mark (the first white path, right after the `#14C8FF` one) and the
`<rect>` inside `<clipPath>`, which is never painted. The upstream network logo keeps
both of these white too. The white file has no `stroke` and no `#fff` or `#FFFFFF`. To
remake the file after a change to the white one, apply the same edit and leave the
`#14C8FF` path, the "t" and the clip rectangle alone.

`covers/technical-specification.png` is the full-page cover artwork of the technical
specification: a soft lavender gradient with a white rounded card and a globe and "t"
watermark at the lower right. It is a Telcoin Association brand asset, copied unchanged
from the images of the April 2026 Google Docs export of the specification, and has no
public URL. It is 1447 by 2048 pixels, 8-bit RGBA. Keep it as it is: do not re-encode,
resize or recompress it.

To refresh a file, fetch it again from the URL above, check it is the right type, and
update the size and date in this table in the same commit. `file` should report "Web Open
Font Format (Version 2)" for a font, "SVG Scalable Vector Graphics image" for a logo and
"PNG image data, 1447 x 2048, 8-bit/color RGBA, non-interlaced" for the cover. A logo
must also still parse as XML and contain only `<svg>`, `<g>`, `<path>`, `<defs>`,
`<clipPath>` and `<rect>` elements. The derived association logo and the cover have no
URL: remake the first from the white logo as described above, and replace the cover only
with a new export of the specification's artwork from the Association.
