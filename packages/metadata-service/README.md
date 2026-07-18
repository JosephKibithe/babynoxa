# @babynoxa/metadata-service

Prepares canonical, factory-ready BabyNoxa metadata under the approved external-media policy.

The service validates every initial and redirect URL against resolved public IP addresses, limits redirects and streamed bytes, detects file type from decoded bytes, fully decodes PNG/JPEG/WebP/GIF content, enforces dimensions, GIF animation limits, and a 256 MiB decoded-RGBA memory ceiling, and hashes the original observed media bytes. Media bytes are not stored.

Canonical metadata JSON is stored through a `StorageAdapter`, immediately retrieved, and hash-verified before the service returns `metadataUri`, `metadataHash`, and `imageHash`. A storage mismatch fails closed.

The included `MemoryStorageAdapter` is for tests and local development. Phase 12 must supply a durable content-addressed adapter.
