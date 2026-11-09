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

**ADC (Application Default Credentials) — fallback only:**

Use ADC only if OAuth2 fails (e.g., keyring issues). Requires a service account or user ADC JSON file.

```bash
# Place ADC JSON in the volume (e.g., via a temporary container)
docker run --rm -v colab-home:/home/colab alpine sh -c 'cat > /home/colab/adc.json' < /path/to/adc.json

# Run with ADC
sh ~/colab-cli/run-colab.sh --auth adc usage

# Verify credentials
sh ~/colab-cli/run-colab.sh --auth adc --logtostderr usage
```

If ADC returns permission errors, revert to OAuth2 (remove `--auth adc`).

### Daily use

```bash
sh ~/colab-cli/run-colab.sh usage              # CU balance and usage rate
sh ~/colab-cli/run-colab.sh new                # create a session
sh ~/colab-cli/run-colab.sh exec < script.py   # execute code
sh ~/colab-cli/run-colab.sh drivemount         # mount Google Drive on Colab VM
sh ~/colab-cli/run-colab.sh ls /content/drive/MyDrive
sh ~/colab-cli/run-colab.sh stop               # release the runtime
sh ~/colab-cli/run-colab.sh sessions           # list active sessions
```

Via SSH from your workstation (nested through a jump host if needed):

```bash
ssh -t <jump-host> 'ssh-free-e2micro01 "sh ~/colab-cli/run-colab.sh usage"'
```

### Data path

Data lives on Google Drive, mounted on the **Colab VM** (not the COS gateway):

```bash
sh ~/colab-cli/run-colab.sh drivemount
sh ~/colab-cli/run-colab.sh exec < analysis.py   # reads /content/drive/MyDrive/...
```

No COS directories need to be bind-mounted into the container. Upload files to Google Drive as needed.

### Key paths inside the volume

| File | Container path | Purpose |
|---|---|---|
| Keyring | `/home/colab/.local/share/python_keyring/keyring_pass.cfg` | OAuth tokens |
| Sessions | `/home/colab/.config/colab-cli/sessions.json` | Active session state |
| OAuth config | `/home/colab/.colab-cli-oauth-config.json` | Client OAuth settings |

Volume location on COS: `/var/lib/docker/volumes/colab-home/_data/`

### Backup

```bash
docker run --rm -v colab-home:/data -v ~/colab-cli:/backup alpine \
  tar czf /backup/colab-home-backup.tar.gz -C /data .
```

Restoring the volume preserves auth tokens. Note: if the OAuth refresh token is revoked server-side (password change, app removal), re-authentication is required regardless of backup.

### Resource limits

The default `run-colab.sh` sets `--memory=512m --memory-swap=512m` for a 1 GB VM. Adjust if needed.

## Security notes

- No tokens or secrets in the image. Auth lives in the `colab-home` volume only.
- The keyring uses plaintext storage (`keyrings.alt.file.PlaintextKeyring`) — restrict volume access.
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