# containers/

This directory holds **local container installer scripts** (often containing secrets).
The repository tracks only **safe templates/docs** here.

## What is tracked
- `containers/README.md`
- `containers/.gitkeep`
- `containers/example-*.sh` / `containers/template-*.sh` (SAFE placeholders only)

## What is ignored (by default)
- Everything else under `containers/` (real installers with tokens)

### Recommended workflow
- Keep real installers in `containers/` locally
- Create sanitized copies as `example-*.sh` for the repo
