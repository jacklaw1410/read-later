# Pack registry

Where the dictionary pack lives so a device can download it. The research
decision is Cloudflare R2 (`findings/F13`, `spec/dictionary-packs.md` §7).

## Layout

```
packs/dictionary.en-zh-HK.lexical/manifest.json
packs/dictionary.en-zh-HK.lexical/2026-11-10.1/dictionary.en-zh-HK.lexical.pack.gz
```

Two rules:

1. **The archive path carries the version.** A version that is published never
   changes, so an installed pack keeps working with no manifest re-fetch.
2. **The manifest path does not.** It is the pointer to the current version, and
   it is short-cached (5 minutes).

The manifest has no download URL. The installer builds the URL from the base,
the pack id and the version in the manifest. The research spec gives the fields
(`spec/dictionary-packs.md` §2).

## Publish

```bash
BUCKET=read-later-dev tools/registry/publish.sh \
  /Users/jack.law/Projects/read-later-research/evidence/2026-11-10-pack-zh-hk/artifacts
```

The script checks `size_bytes` and `sha256` against the archive before it
uploads. A mismatch stops the run.

## Bucket

| Field | Value |
|---|---|
| Name | `read-later-dev` |
| Account id | `c77a4d6bb743471e72f2e9805aaeac5d` |
| Public URL | `https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev` |
| Created | 2026-11-12 |

The bucket is created and the public URL is enabled with:

```bash
wrangler r2 bucket create read-later-dev
wrangler r2 bucket dev-url enable read-later-dev
```

The `r2.dev` address is the development endpoint. It is rate limited and it is
not a production address. Replace it with a custom domain before release.

## What is published

Both packs from `evidence/2026-11-10-pack-zh-hk/artifacts`, version `2026-11-10.1`.

| Pack | Archive bytes | sha256 (first 12) |
|---|---|---|
| `dictionary.en-zh-HK.lexical` | 15,171,897 | `769256b3f334` |
| `dictionary.en-zh-HK.gloss` | 13,499,239 | see its manifest |

The `lexical` pack is the one the app installs. The `gloss` pack has no surface
and no document quotes its size (`spec/dictionary-packs.md` §1).

## Check a deploy

```bash
BASE=https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev
curl -fsS "$BASE/packs/dictionary.en-zh-HK.lexical/manifest.json" | python3 -m json.tool
curl -fsS "$BASE/packs/dictionary.en-zh-HK.lexical/2026-11-10.1/dictionary.en-zh-HK.lexical.pack.gz" -o /tmp/pack.gz
wc -c < /tmp/pack.gz
shasum -a 256 /tmp/pack.gz
```

The release check in `spec/dictionary-packs.md` §3 rule 8 fetches the manifest
and one archive, and compares the status, the size and the sha256. A failure
stops the release.

**Measured 2026-11-12.** Manifest 200. Archive 200, `Content-Type:
application/gzip`, `Content-Length: 15171897`. Downloaded size 15,171,897 bytes.
Downloaded sha256 `769256b3f33470a0271c8b3f74fe1e0eb7e9dd53ae58bc42292ca305168359a7`,
equal to the manifest. Both match the file on disk.

## Cost

R2 charges for storage and for reads outside the free tier. At 30 MB stored and
a few hundred downloads a day, the monthly cost stays under the free allowance.
Check the spending limit in the dashboard before the first public build.

## Next

`PackRegistry` still installs the bundled demo pack. D11 needs the network path:
fetch the manifest, verify every field, download the archive, verify the
`sha256`, then install. The URL stays out of the tap path.
