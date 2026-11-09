# colab-cli-docker

Docker image for [google-colab-cli](https://github.com/googlecolab/google-colab-cli) — a thin client that runs compute on remote Colab VMs (CPU/GPU/TPU). Built via Google Cloud Build and stored in Artifact Registry.

## Architecture

```
GitHub (source) → Cloud Build (build+push) → Artifact Registry → COS VM (docker run) → Colab VM (compute)
```

The container is a thin client only. Heavy data stays on Google Drive via `colab drivemount` (mounted on the Colab VM, not the gateway).

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

### First-time setup

```bash
# Configure credential helper (COS has docker-credential-gcr pre-installed)
docker-credential-gcr configure-docker --registries=<REGION>-docker.pkg.dev

# Pull the image
docker pull <REGION>-docker.pkg.dev/<PROJECT>/<REPO>/colab-cli:<TAG>

# Create persistent volume for auth tokens
docker volume create colab-home

# Authenticate (interactive — opens URL, paste code back)
docker run --rm -it -v colab-home:/home/colab <IMAGE> auth
```

### Daily use

```bash
# Via run-colab.sh (placed on the VM)
./run-colab.sh balance
./run-colab.sh new
./run-colab.sh exec < script.py
./run-colab.sh drivemount
./run-colab.sh stop

# Or via SSH from your workstation
ssh <vm-alias> '~/colab-cli/run-colab.sh balance'
```

### Key paths inside the volume

- Keyring: `/home/colab/.local/share/python_keyring/keyring_pass.cfg`
- Auth persists across container restarts (volume-backed)

### Resource limits

The default `run-colab.sh` sets `--memory=512m --memory-swap=512m` for a 1 GB VM. Adjust if needed.

## Security notes

- No tokens or secrets in the image. Auth lives in the `colab-home` volume only.
- The keyring uses plaintext storage (`keyrings.alt.file.PlaintextKeyring`) — restrict volume access.
- The Artifact Registry repository is private; the VM service account needs `roles/artifactregistry.reader`.
- This repository is private. The project ID in `run-colab.sh` is not a credential.

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