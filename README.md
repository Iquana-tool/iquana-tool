# IQUANA

**I**nteractive **QU**antification, **AN**notation and **A**nalysis — a tool for AI-assisted segmentation,
annotation and quantification of scientific datasets, built at [DFKI](https://www.dfki.de/).

This repository is the entry point for the whole tool. It contains

- the **installer**, which sets up every IQUANA component on your machine, and
- the **issue tracker** for all of IQUANA — bug reports and feature requests for the
  frontend, the backend, the AI service and the installer all belong
  [here](https://github.com/Iquana-tool/iquana-tool/issues/new/choose).

## Quick start

```bash
git clone https://github.com/Iquana-tool/iquana-tool.git
cd iquana-tool
./install.sh
```

The installer asks for the release channel, the ports, whether to install with CUDA
support, and your HuggingFace token. It then clones the component repositories, wires
their configuration together, installs all dependencies and offers to start the tool.
The first run downloads several GB and takes a while.

When it is done, IQUANA is at **http://localhost:3000**.

## Prerequisites

| | why | install |
|---|---|---|
| **git** | fetching the component repositories | https://git-scm.com/downloads |
| **uv** ≥ 0.10 | Python environments for the backend and the AI service | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **bun** | the React frontend | `curl -fsSL https://bun.sh/install \| bash` |
| **Docker** | the PostgreSQL database and the Redis task broker run as containers and **cannot** be started without a container runtime | https://docs.docker.com/get-docker/ |

Podman is accepted as a drop-in replacement for Docker. An NVIDIA GPU is optional but
strongly recommended — without one, model inference and training run on the CPU.

The installer is written for Linux and macOS. On Windows, run it inside WSL 2.

## Running IQUANA

```bash
./iquana.sh start            # start everything
./iquana.sh stop             # stop everything
./iquana.sh restart          # stop, then start
./iquana.sh status           # what is running, on which port, at which commit
./iquana.sh logs backend -f  # follow one service's log
```

Every command also takes a list of services, e.g. `./iquana.sh restart ai-service ai-worker`.

| service | what it does | default port |
|---|---|---|
| `frontend` | the web UI you annotate in | 3000 |
| `backend` | REST API, database, exports | 8000 |
| `ai-service` | model inference for all AI-assisted tasks | 8004 |
| `ai-worker` | Celery worker for model training | — |
| `backend-worker` | Celery worker for batch inference runs | — |
| `mlflow` | model and experiment tracking | 5000 |
| `postgres` | the database (container) | 5432 |
| `redis` | task broker for both workers (container) | 6379 |

Logs are written to `logs/`, one file per service.

## Updating

Re-run the installer. It checks every repository for new commits, shows you what changed,
and asks before applying anything or restarting the running services.

```bash
./install.sh
```

Checkouts with uncommitted local changes are left untouched, so you can develop inside
`backend/` or `frontend-react/` without the installer overwriting your work.

### Stable vs. dev

- **stable** — the `main` branch of every repository. This is what you want.
- **dev** — the `dev` branch where a repository has one, `main` otherwise. Newer features,
  but expect breakage.

Switch channels with `./install.sh --reconfigure`.

## Configuration

All answers are stored in `iquana.conf` next to the installer (mode `600`, gitignored — it
holds your tokens and the generated database password and signing key). From it the
installer generates the per-service configuration:

- `backend/.env` — database, Redis, MLflow and AI-service URLs, CORS origins, signing key
- `ai-service/.env` — HuggingFace token, Redis and MLflow URLs
- `frontend-react/.env.local` — the API URL the browser calls, and the frontend's port

To change something, either run `./install.sh --reconfigure` or edit `iquana.conf` by hand
and re-run `./install.sh`. Editing the generated `.env` files directly works too, but the
next installer run will replace them (keeping a `.bak` copy).

### Serving IQUANA to other machines

Answer the installer's hostname question with the hostname or IP other machines use to
reach the server, rather than `localhost`. That value goes into the frontend's API URL and
into the backend's allowed CORS origins.

### Optional integrations

- **HuggingFace token** — needed for gated model weights (SAM, DINOv3, …).
  Create a read token at https://huggingface.co/settings/tokens.
- **LLM API key** — enables the "describe your label space" assistant. Any
  [LiteLLM](https://docs.litellm.ai/docs/providers)-supported provider works; the model is
  named `<provider>/<model>`, e.g. `anthropic/claude-opus-4-8` or `ollama/llama3`.

## Installer options

```
./install.sh                 interactive install or update
./install.sh --reconfigure   go through the configuration questions again
./install.sh --yes           accept every stored/default answer, no prompts
./install.sh --no-start      set everything up, but do not start the services
```

## What gets installed where

The installer clones the components as sibling directories inside this repository:

```
iquana-tool/
├── install.sh            setup and updates
├── iquana.sh             start / stop / status / logs
├── iquana.conf           your answers (secrets, gitignored)
├── backend/              REST API, database models, exports
├── frontend-react/       the web UI
├── ai-service/           unified AI service (inference + training)
├── logs/                 one log file per service
└── .mlflow/              MLflow tracking database and artifacts
```

Nothing is installed outside this directory except the container volume
`iquana-pg-data` (the database) and the containers `iquana-pg` and `iquana-redis`.

## Troubleshooting

**"no container runtime found"** — Docker is not installed or the daemon is not running.
Start Docker Desktop (or `podman machine start`) and run the installer again.

**A port is already in use** — the installer warns and lets you pick another one. To change
ports later, run `./install.sh --reconfigure`.

**A service will not start** — check its log: `./iquana.sh logs ai-service`. The AI service
in particular can take a few minutes on its first start while it downloads model weights.

**"uv is too old"** — run `uv self update`. Versions below 0.10 reject the PyTorch wheels
the AI service needs.

## Reporting bugs and requesting features

Please use the [issue templates](https://github.com/Iquana-tool/iquana-tool/issues/new/choose).
For bugs, steps to reproduce and a screenshot help enormously; for feature requests, a
sketch or mockup does.

We are a small research team and cannot promise to implement every request. If you would
like to bring IQUANA to your own domain, or are interested in a research collaboration,
write to **robert.leist@dfki.de**.

## License

See [LICENSE](LICENSE).
