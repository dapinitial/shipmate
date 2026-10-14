# Vendored code

| File | Source | Version | License | SHA-256 |
|---|---|---|---|---|
| `qrcode.js` | npm `qrcode-generator` (Kazuhiko Arase) | 1.4.4 | MIT (header in file) | `18ae399f81182bc9de916e9c77b195df20cc58d6f2d55a62b085a299f1bf1780` |

Vendored, not installed, so shipmate stays zero-dependency. Used server-side only, to draw the
authenticator-app QR code as an inline SVG. To update: `npm pack qrcode-generator@<ver>`, copy
`package/qrcode.js`, and record the new checksum here.
