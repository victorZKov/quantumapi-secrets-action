<!-- This repo is synced automatically from
     https://github.com/victorZKov/quantumapi/tree/main/src/integrations/github-action
     Do not edit files here directly — open a PR against the monorepo. -->

# QuantumAPI Secrets Action

Fetch secrets from [QuantumVault](https://quantumapi.eu) and expose them as
masked environment variables in your GitHub Actions workflow.

> **Source of truth:** this action is developed in the QuantumAPI monorepo
> under [`src/integrations/github-action/`](https://github.com/victorZKov/quantumapi/tree/main/src/integrations/github-action)
> and synced to [`victorZKov/quantumapi-secrets-action`](https://github.com/victorZKov/quantumapi-secrets-action)
> on every `gh-action/v*` tag. Use the standalone repo in your `uses:` line.

## Quick start

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Inject QuantumVault secrets
        uses: victorZKov/quantumapi-secrets-action@v1
        with:
          api-key: ${{ secrets.QAPI_API_KEY }}
          secret-paths: |
            DB_PASSWORD=prod/db/password
            STRIPE_KEY=prod/stripe/api_key

      - name: Deploy
        run: ./deploy.sh
        # DB_PASSWORD and STRIPE_KEY are now in env, masked in the log.
```

## Inputs

| Name           | Required | Default                     | Description                                                                                            |
| -------------- | -------- | --------------------------- | ------------------------------------------------------------------------------------------------------ |
| `api-key`      | yes      | —                           | QuantumAPI API key with `secrets:read` scope. Pass via `${{ secrets.QAPI_API_KEY }}`.                  |
| `secret-paths` | yes      | —                           | Newline-separated list of `ENV_VAR=secret-name` mappings. Lines starting with `#` are comments.        |
| `endpoint`     | no       | `https://api.quantumapi.eu` | API endpoint (override for self-hosted / on-prem deployments).                                         |
| `export-env`   | no       | `true`                      | When `true`, values are written to `$GITHUB_ENV`. When `false`, they are still masked but not exported.|
| `secrets-file` | no       | `''`                        | When set to an absolute path, fetched secrets are also written as `KEY=value` lines (mode 0600).       |
| `cache`        | no       | `false`                     | When `true`, results are memoized for the lifetime of the job (job-scoped, not pipeline-scoped).       |

## Outputs

| Name             | Description                                                                          |
| ---------------- | ------------------------------------------------------------------------------------ |
| `injected-vars`  | Comma-separated list of environment variable names that were injected (e.g. `A,B`).  |
| `cache-hit`      | `true` when a previous step in this job already fetched the same set of paths.       |

## Optional: write secrets to a file

For tools that read configuration from a `.env`-style file (Docker, Compose, dotenv-loaders), set `secrets-file`:

```yaml
- uses: victorZKov/quantumapi-secrets-action@v1
  with:
    api-key: ${{ secrets.QAPI_API_KEY }}
    secrets-file: ${{ runner.temp }}/app.env
    secret-paths: |
      DB_PASSWORD=prod/db/password
      STRIPE_KEY=prod/stripe/api_key

- run: docker run --env-file ${{ runner.temp }}/app.env myapp:latest
- run: rm -f ${{ runner.temp }}/app.env   # caller cleans up
```

The file is created with mode 0600 (owner read/write only). It is the caller's responsibility to remove it when done — leaving it on a self-hosted runner is dangerous.

## Optional: in-job cache

If multiple steps in the same job need the same secrets, set `cache: true`. The first invocation fetches and writes a marker to `$GITHUB_STATE`; subsequent invocations with the **same set of paths** short-circuit and reuse the values already injected into `$GITHUB_ENV`. The cache key is derived from a SHA-256 of the sorted `KEY=path` pairs, so reordering or whitespace differences yield the same key but adding/removing a path invalidates it. Cache is job-scoped — it does not persist across jobs in the same workflow.

## Security

- The API key is registered as a GitHub Actions mask via `::add-mask::` as soon as the action starts.
- Each fetched secret value is also masked (`::add-mask::`) before it is exported, so it appears as `***` in any subsequent log output, regardless of the runner OS or shell.
- The action never prints values; it only logs `[QuantumAPI] injected NAME from path ([MASKED])`.
- Multi-line secrets are written using the `$GITHUB_ENV` heredoc form, so newlines are preserved.

## Runner requirements

- `bash`, `curl`, `jq` — all preinstalled on the standard `ubuntu-latest`, `macos-latest`, and `windows-latest` (Git Bash) runners. For minimal containers, install them in your job before this step.

## Tests

Unit tests for the entrypoint live in `test/inject-secrets.bats`. They use a `curl` shim placed early on `$PATH` to exercise the parser offline. Run them with [`bats-core`](https://github.com/bats-core/bats-core):

```bash
bats test/inject-secrets.bats
```

## Backend endpoint dependency

The action calls `GET /api/v1/secrets/by-name/{name}?includeValue=true`. As of issue #226 scaffolding, this endpoint may not exist in the .NET backend yet — see TODO in `inject-secrets.sh`. Either:

1. Add a name-based lookup endpoint server-side (preferred), or
2. Update this action to first GET `/api/v1/secrets?search={name}`, resolve the GUID, then GET `/api/v1/secrets/{id}?includeValue=true`.

## Releasing

Releases are cut from the monorepo. Tagging `gh-action/vX.Y.Z` runs
[`.github/workflows/release-github-action.yml`](../../../.github/workflows/release-github-action.yml),
which mirrors this directory to the standalone repo
[`victorZKov/quantumapi-secrets-action`](https://github.com/victorZKov/quantumapi-secrets-action),
creates `vX.Y.Z`, and force-moves the rolling `v<major>` tag (e.g. `v1`) for
stable releases. Prereleases (`gh-action/vX.Y.Z-rc.1`) only push the exact tag.

```bash
# Cut a release
git tag gh-action/v1.0.0
git push origin gh-action/v1.0.0
```

### One-time setup

1. Create the standalone repo `victorZKov/quantumapi-secrets-action` (empty,
   public, default branch `main`, with at least one commit so the workflow can
   push to it — an empty README is fine).
2. Generate a fine-grained PAT with **Contents: Read and write** on that repo.
3. Add it as a monorepo Actions secret: `STANDALONE_ACTION_PUSH_TOKEN`.
4. Cut the first release (`gh-action/v1.0.0`). The workflow pushes the
   `v1.0.0` and `v1` tags and creates a release. **First release only:** open
   the release on the standalone repo and tick *Publish this Action to the
   GitHub Marketplace*. Subsequent releases inherit the listing automatically.

## License

Apache-2.0 — see [LICENSE](LICENSE).
