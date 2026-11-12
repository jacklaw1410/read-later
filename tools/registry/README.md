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
| Bucket id | not created yet |
| Public URL | not created yet |

The bucket is created with:

```bash
wrangler r2 bucket create read-later-dev
```

The `r2.dev` address is the development endpoint. It is rate limited and it is
not a production address. Replace it with a custom domain before release.

## Check a deploy

```bash
curl -fsS https://<public-url>/packs/dictionary.en-zh-HK.lexical/manifest.json | python3 -m json.tool
curl -fsSI https://<public-url>/packs/dictionary.en-zh-HK.lexical/2026-11-10.1/dictionary.en-zh-HK.lexical.pack.gz | head
```

The release check in `spec/dictionary-packs.md` §3 rule 8 fetches the manifest
and one archive, and compares the status, the size and the sha256. A failure
stops the release.

## Next

`PackRegistry` still installs the bundled demo pack. D11 needs the network path:
fetch the manifest, verify every field, download the archive, verify the
`sha256`, then install. The URL stays out of the tap path.
