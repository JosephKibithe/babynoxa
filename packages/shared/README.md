# @babynoxa/shared

Framework-neutral V1 contracts for metadata, launches, tokens, trades, lifecycle state, and indexed events.

`parseMetadataV1` enforces the V1 field and URL rules. Image URL and website are optional; supplied URLs must pass the same strict HTTPS checks, and a supplied image must have its observed content hash. `canonicalJson` recursively sorts object keys and rejects non-JSON numeric values so logically identical metadata always produces the same SHA-256 commitment.

```ts
import { canonicalJson, parseMetadataV1, sha256Hex } from "@babynoxa/shared";

const metadata = parseMetadataV1(input);
const json = canonicalJson(metadata);
const metadataHash = sha256Hex(json);
```

Only schema version 1 is accepted. New schema versions require a new parser and explicit compatibility tests rather than silently changing V1 serialization.
