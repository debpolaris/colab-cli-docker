# colab-cli-docker

Docker image for [google-colab-cli](https://github.com/googlecolab/google-colab-cli) — a thin client that runs compute on remote Colab VMs (CPU/GPU/TPU). Built via Google Cloud Build and stored in Artifact Registry.

## Architecture

```
GitHub (source) → Cloud Build (build+push) → Artifact Registry → COS VM (docker run) → Colab VM (compute)
```

The container is a thin client only. Heavy data stays on Google Drive via `colab drivemount` (mounted on the Colab VM, not the gateway). No local data directories need to be mounted into the container.

## Build

### Prerequisites

- GCP project with billing enabled
- APIs enabled: `cloudbuild.googleapis.com`, `artifactregistry.googleapis.com`
- Artifact Registry Docker repository (private, same region as VM)
- `gcloud` CLI authenticated with sufficient permissions

### Submit a build

```bash
gcloud builds submit --config=cloudbuild.yaml --project=<PROJECT_ID> .
```

### Configuration (cloudbuild.yaml)

| Substitution | Default | Description |
|---|---|---|
| `_REGION` | `us-central1` | Artifact Registry region. Change to match your VM region for free egress. |
| `_REPO` | `colab-cli` | Repository name in Artifact Registry. |
| `_TAG` | `0.7.5` | Image tag. Set to the colab-cli version being built. |

Override at submit time:

```bash
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=_REGION=us-east1,_TAG=0.8.0 .
```

### Cleanup policy (cleanup-policy.json)

Default rules:

- **keep-recent-3**: Always keep the 3 most recent versions (regardless of age).
- **delete-old-30d**: Delete any version older than 30 days (unless protected by the keep rule).

Apply to a repository:

```bash
gcloud artifacts repositories set-cleanup-policies <REPO> \
  --location=<REGION> --policy=cleanup-policy.json --project=<PROJECT_ID>
```

Adjust `keepCount` or `olderThan` as needed. The keep rule takes precedence over delete.

## Update

1. Change the version pin in `Dockerfile` (`google-colab-cli==<NEW_VERSION>`)
2. Update `_TAG` in `cloudbuild.yaml` to match
3. Update `IMAGE` in `run-colab.sh` to the new tag
4. Commit and push
5. Submit build: `gcloud builds submit --config=cloudbuild.yaml .`
6. On the VM: `docker pull <NEW_IMAGE>`

The container uses `--rm` and read-only layers, so `colab update --install` inside the container does not persist. Always rebuild to update.

**Note:** Cloud Build substitutions (`_REGION`, `_REPO`, `_TAG`) only affect the image built and pushed to Artifact Registry. They do **not** propagate to `run-colab.sh` — it is a static script deployed to the VM, not a build artifact. Keep the three version references in sync manually (Dockerfile pin, `_TAG` substitution, `run-colab.sh` IMAGE line).

Check available versions: https://pypi.org/project/google-colab-cli/#history

## Usage (on the VM)

### COS noexec note

Container-Optimized OS mounts the stateful partition (where home directories live) with `noexec`. Scripts cannot be executed directly (`./run-colab.sh` will fail with "Permission denied"). Always invoke via `sh`:

```bash
sh ~/colab-cli/run-colab.sh <command>
```

This applies to all scripts on the stateful partition. There is no functional limitation — `sh` invocation works identically.

### First-time setup

```bash
# Configure credential helper (COS has docker-credential-gcr pre-installed)
docker-credential-gcr configure-docker --registries=<REGION>-docker.pkg.dev

# Pull the image
docker pull <REGION>-docker.pkg.dev/<PROJECT>/<REPO>/colab-cli:<TAG>

# Create persistent volume for auth tokens
docker volume create colab-home

# Place run-colab.sh on the VM
mkdir -p ~/colab-cli
# (copy or create run-colab.sh here)
```

### Authentication

There is no standalone `auth` command. Authentication is triggered automatically when you run a command that requires account access for the first time.

**OAuth2 (default, recommended for headless):**

```bash
sh ~/colab-cli/run-colab.sh usage
```

On first run, the CLI prints an authorization URL. Open it in a browser, sign in, and paste the code back into the terminal. The token is stored in the `colab-home` volume and persists across container restarts.

**ADC (Application Default Credentials) — verified working:**

ADC is accepted by the Colab control plane (verified 2026-11-09, colab-cli 0.7.5): `usage`, `new` (CPU and T4 GPU), `exec`, and `stop` all work with `--auth adc`.

Setup: run `gcloud auth application-default login` on a machine with gcloud (COS has none), then place the JSON at the well-known path inside the volume:

```bash
# Stream from the gcloud machine into the volume (do not display contents)
cat application_default_credentials.json | docker run --rm -i \
  -v colab-home:/home/colab --entrypoint sh <IMAGE> -c \
  'mkdir -p /home/colab/.config/gcloud && cat > /home/colab/.config/gcloud/application_default_credentials.json && chown 1000:1000 /home/colab/.config/gcloud/application_default_credentials.json && chmod 600 /home/colab/.config/gcloud/application_default_credentials.json'
```

```bash
# Run with ADC
sh ~/colab-cli/run-colab.sh --auth adc usage

# Verify credentials
sh ~/colab-cli/run-colab.sh --auth adc --logtostderr usage
```

ADC and OAuth2 coexist in the volume (`token.json` + `application_default_credentials.json`); the `--auth` flag selects between them, and neither interferes with the other.

**Limitation common to both auth methods:** `drivemount` still requires the interactive browser authorization on every new session, even with ADC. The Drive credential flow (`authorize-for-drive-credentials-ephemeral`) is bound to the VM endpoint and enforced server-side (`prompt=consent`) — independent of how the CLI authenticates to the control plane.

### Daily use

```bash
sh ~/colab-cli/run-colab.sh usage              # CU balance and usage rate
sh ~/colab-cli/run-colab.sh new                # create a session (required before drivemount)
sh ~/colab-cli/run-colab.sh drivemount         # mount Drive (interactive, per-session auth)
sh ~/colab-cli/run-colab.sh exec < script.py   # execute code
sh ~/colab-cli/run-colab.sh ls /content/drive/MyDrive
sh ~/colab-cli/run-colab.sh stop               # release the runtime (stops CU consumption)
sh ~/colab-cli/run-colab.sh sessions           # list active sessions
```

Typical workflow: `new` → `drivemount` → work → `stop`. Always `stop` when done to avoid CU drain.

Via SSH from your workstation (nested through a jump host if needed):

```bash
ssh -t <jump-host> 'ssh-free-e2micro01 "sh ~/colab-cli/run-colab.sh usage"'
```

For interactive commands (drivemount), ensure TTY is allocated through the full SSH chain (`ssh -t`).

### Data path

Data lives on Google Drive, mounted on the **Colab VM** (not the COS gateway):

```bash
sh ~/colab-cli/run-colab.sh new                # 1. create session first
sh ~/colab-cli/run-colab.sh drivemount         # 2. mount Drive (browser auth required)
sh ~/colab-cli/run-colab.sh exec < analysis.py # 3. reads /content/drive/MyDrive/...
sh ~/colab-cli/run-colab.sh stop               # 4. release when done
```

No COS directories need to be bind-mounted into the container. Upload files to Google Drive as needed.

**Important:** `drivemount` requires an active session (`new` first). Drive authorization is **per-session** — each new Colab VM requires a fresh browser authorization. This is by design (the OAuth token is bound to the VM endpoint).

### Auth persistence summary

| Credential | Persists? | Notes |
|---|---|---|
| Colab API token (`token.json`) | **Yes** | Survives container restarts and new sessions. One-time auth. |
| Drive mount authorization | **No** | Per-session. Must re-authorize in browser after each `new`. |

### Key paths inside the volume

Actual files written by colab-cli 0.7.5 (verified on the VM):

| File | Container path | Purpose |
|---|---|---|
| OAuth token | `/home/colab/.config/colab-cli/token.json` | Colab API credentials (persistent) |
| Settings | `/home/colab/.config/colab-cli/settings.json` | Session/account settings |
| Lock file | `/home/colab/.config/colab-cli/settings.json.lock` | Settings lock |
| Log | `/home/colab/.config/colab-cli/colab.log` | CLI log |

Note: colab-cli 0.7.5 does **not** use the OS keyring — tokens are stored directly in `token.json`. The `keyrings.alt` package and `PYTHON_KEYRING_BACKEND` env var in the Dockerfile are harmless but unnecessary for this version.

Volume location on COS: `/var/lib/docker/volumes/colab-home/_data/`

### Backup

```bash
docker run --rm -v colab-home:/data -v ~/colab-cli:/backup alpine \
  tar czf /backup/colab-home-backup.tar.gz -C /data .
```

Restoring the volume preserves auth tokens. Note: if the OAuth refresh token is revoked server-side (password change, app removal), re-authentication is required regardless of backup.

### Verified GPU behavior (tested on AI Plus tier, colab-cli 0.7.5)

- `new --gpu T4` allocates a Tesla T4 successfully on the AI Plus tier. Supported variants: T4, L4, G4, H100, A100.
- CUDA is available inside the session (`torch.cuda.is_available()` → True).
- CU burn rate (measured via `usage`):
  - CPU session: **0.08/hr**
  - T4 GPU session: **1.15/hr** (~14× CPU)
- With a 50 CU/month allocation, continuous GPU time is limited to roughly **43 hours/month**; CPU allows roughly **625 hours/month**.
- `--high-mem` requires Colab Pro/Pro+ (not available on AI Plus).
- Stop GPU sessions immediately after use (`stop`) — the 14× rate drains CU fast.

### Known anomaly: balance always 0.00 (verified, AI Plus tier)

`usage` reports `Current balance: 0.00 compute units` under **both** OAuth2 and ADC authentication (two independent credential systems), while session creation and code execution work normally and the usage rate ticks up while a session is active (0.08/hr CPU, 1.15/hr T4). Since two unrelated auth mechanisms return the same 0.00, this is not a CLI/auth issue — it indicates the subscription allocation is not visible to the CLI's balance API for this account. **Tested on the AI Plus tier only** — subscribers to Colab Pro / Pro+ may see balances reported correctly. Sessions still run; check actual CU consumption in the Colab web UI (colab.research.google.com).

### Resource limits

The default `run-colab.sh` sets `--memory=512m --memory-swap=512m` for a 1 GB VM. Adjust if needed.

## Limitations

- **Interactive flows require a human.** `input()` prompts inside executed code and browser-consent flows (`drivemount` per-session authorization, first-time OAuth) cannot be completed headlessly or by an automation agent — a user must complete them interactively. Ordinary code errors are returned as tracebacks in the command output, so an agent or script can inspect the output, fix the code, and re-run `exec` until it works.
- **`run` timeout defaults to 30 seconds.** Long-running scripts need `--timeout <seconds>` (e.g. `sh ~/colab-cli/run-colab.sh run --timeout 3600 script.py`) or should be executed via `exec` on a persistent session instead.

## Security notes

- No tokens or secrets in the image. Auth lives in the `colab-home` volume only.
- OAuth tokens are stored as plaintext JSON (`token.json`) — restrict volume access.
- The Artifact Registry repository is private; the VM service account needs `roles/artifactregistry.reader`.
- The project ID in `run-colab.sh` is not a credential — it grants no access without authentication.

## Rollback / removal

```bash
# On the VM
docker rmi <IMAGE>
docker volume rm colab-home   # destroys auth tokens

# GCP
gcloud artifacts docker images delete <IMAGE>
gcloud artifacts repositories delete <REPO> --location=<REGION>
```

Revoke OAuth tokens: Google Account → Security → Third-party apps → remove access.