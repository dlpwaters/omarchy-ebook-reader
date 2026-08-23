# Security

Leaf Reader is local-first. Its helper listens only on `127.0.0.1`, uses a random per-process token for state-changing requests, and serves only bundled assets plus files already identified by the library scanner.

Book metadata is always rendered as plain text in the Omarchy panel. EPUB container XML is capped at 64 KiB and package XML at 2 MiB from ZIP descriptors before decompression, with the actual reads independently capped; sidecar package metadata uses the same 2 MiB ceiling. Raw cover files never reach the long-running shell: Leaf Reader accepts only bounded JPEG/PNG inputs, rejects sources above 8 MiB, 4096 pixels on either side, or 12 megapixels, then decodes the first frame in a short-lived ImageMagick process with explicit memory, mapped-memory, disk, thread, time, width, height, and area limits. Only a verified PNG no larger than 512×768 and 3 MiB is cached for the panel, whose QML `Image` items also set explicit `sourceSize` bounds.

Please report a vulnerability through GitHub's private security-advisory form for this repository. Do not include private ebook files, API keys, or reading-history data in a public issue.
