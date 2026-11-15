# Contributing to Pigeon

Thanks for helping out. This file covers how to make a change and how to
describe it in a commit. For the architecture, specifications, and coding
conventions, read [`AGENTS.md`](AGENTS.md) first.

## Commit messages

Pigeon uses Conventional Commits:

```
type(scope): summary
```

The summary is lowercase, written in the imperative mood, and has no trailing
period.

### Types

| Type | Use for |
| --- | --- |
| `feat` | A new user-visible capability |
| `fix` | A bug fix |
| `docs` | Specification, README, or comment-only changes |
| `refactor` | Code restructuring with no behavior change |
| `perf` | A change that improves speed or memory use |
| `test` | Test-only changes |
| `build` | Cabal, Docker, or dependency changes |
| `ci` | Workflow and automation changes |
| `chore` | Everything else, such as releases and housekeeping |

### Scopes

The only scopes are `client` and `server`:

```
feat(client): add --insecure flag
fix(server): reject truncated gzip members
```

Use `client` when the change only affects `pigeon-client`, and `server` when it
only affects `pigeon-server`.

**If a commit affects both, leave the scope out:**

```
docs: describe the upload expiry rule
feat: accept PIGEON_NO_TLS as a fallback
```

A commit that touches shared code (`src/Pigeon/API.hs`, `src/Pigeon/Types.hs`,
`specs/`, CI, or the build) affects both sides as well, so it also has no
scope. Do not invent other scopes such as `specs`, `deps`, or `db`.

### Examples

```
feat(server): apply a default expiry to every upload
fix(client): print errors to stderr in --json mode
chore: release v0.1.1.0
```

### Body and trailers

Use the body when the reason for the change is not obvious from the summary.
Explain what was wrong and why the change fixes it, and reference requirement
IDs (`NET-004`, `STORE-011`, `SRV-003`, and so on) when a behavior is
non-obvious. Wrap the body at 72 columns.

## Before you commit

Run the checks described in [`AGENTS.md`](AGENTS.md):

```bash
cabal build all
cabal test all
fourmolu --mode check src app test
hlint src app test
```

If behavior changed, update the relevant spec in `specs/` and `CHANGELOG.md` in
the same commit. New entries go under the `## Unreleased` section at the top of
`CHANGELOG.md`; do not add them to an already released version. Create that
section if it is missing, and only move entries into a version section when
preparing a release. Never commit secrets, tokens, passwords, or real file
contents, including in test fixtures and logs.
