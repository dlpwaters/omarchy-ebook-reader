# Changelog

## 1.1.4 — 2026-08-23

- Reject oversized EPUB container and package XML from ZIP descriptors before decompression or parsing
- Cap actual ZIP-member reads even when archive metadata is malformed, and reject encrypted or unsafe metadata paths
- Apply the same package-metadata ceiling to sidecar `metadata.opf` files

## 1.1.3 — 2026-08-22

- Reject covers larger than 8 MiB, 4096 pixels on either side, or 12 megapixels before decoding
- Decode JPEG/PNG covers in a short-lived, resource-limited ImageMagick process and cache only verified 512×768 PNG thumbnails
- Keep raw EPUB and sidecar cover bytes out of the long-running Omarchy shell and add explicit QML decode-size bounds
- Invalidate older cover records so existing libraries are safely reprocessed on their next scan

## 1.1.2 — 2026-08-21

- Force ebook title, author, and status metadata to render as plain text in the native library panel
- Keep untrusted book metadata out of the shared Omarchy bar tooltip
- Call out Night dark mode explicitly in the appearance gallery

## 1.1.1 — 2026-08-21

- Reliable foreground colors when switching between Night, Sepia, and Paper themes
- Expanded README visuals for the native library panel and reading color options
- Clearer descriptions of appearance and page-turn controls

## 1.1.0 — 2026-08-21

- Four reviewed public-domain starter books for an immediately useful offline shelf
- Fresh installs prefer an existing `~/Books` library, then fall back to the bundled starter shelf
- Crisper Noto Serif/Noto Sans rendering across the reader and library panel
- Correct two-page viewport width that preserves publisher pagination and the book-like spread
- Page turns no longer wake the top and bottom reader controls
- Controls now respond deliberately to pointer movement, click/tap, and Escape
- Optional page-turn effect, controllable from both reader appearance and Omarchy settings
- Current Omarchy panel-switching contract and single-instance manifest declaration
- Conflict-free ephemeral loopback port passed explicitly to the native reader
- Off-the-record WebEngine profile with outbound networking disabled for book content
- Defensive ebook ignores and provenance records to prevent private libraries from entering releases

## 1.0.0 — 2026-08-21

- Native Omarchy library panel with cover grid, search, sorting, and folder selection
- Exact EPUB CFI resume, reading percentage, chapter state, and bookmarks
- Direct offline EPUB and PDF reading
- Optional local conversion and caching for AZW3, MOBI, AZW, PRC, FB2, FBZ, HTMLZ, RTF, TXT, and TXTZ
- Paper, Sepia, Slate, and Night reading themes
- Font, text size, line spacing, reading width, and paginated/scrolled layout controls
- Realistic 3D page turns with reduced-motion support
- Table of contents, in-book search, progress scrubbing, and keyboard navigation
- Crash-isolated Qt 6 reader process with deterministic Hyprland fullscreen activation
