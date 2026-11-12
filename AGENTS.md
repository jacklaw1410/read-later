# read-later — agent notes

Commit and branch rules live in
[`../read-later-research/AGENTS.md`](../read-later-research/AGENTS.md). That file
is the source of truth; this one only repeats the merge rule, because an agent
can open this repo alone.

Land a feature branch as one squash commit on `main`:

```bash
git switch <branch>
git rebase main
git switch main
git merge --squash <branch>
git commit
```

One branch, one commit.

Build, test, device and troubleshooting instructions:
[`README.md`](README.md) and [`apps/apple/README.md`](apps/apple/README.md).

Design values come from `design/tokens.json` only. A view reads a semantic
name, never a hex or a point. After a token edit, run
`python3 tools/tokens/generate.py`, then `./tools/tokens/check.sh`. Do not edit
a file under `Generated/` or `design/generated/`. Layers and the portability
boundary: [`docs/design-system.md`](docs/design-system.md).
