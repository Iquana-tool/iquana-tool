# Coral Annotation Tool

A super repository that combines all services required for the Coral annotation tool as git submodules.

## Overview

This repository orchestrates the following services:

- **coral-front**: React frontend application (Port 3000)
- **coral-back**: Main backend API server (Port 8000)
- **coral-prompted-seg**: Prompted segmentation service using SAM models (Port 8001)
- **coral-semantic-seg**: Semantic/automatic segmentation service (Port 7000)
- **coral-completion-seg**: Completion segmentation service (Port 8003)

## Getting Started

### 1. Clone the Repository with Submodules

```bash
# Clone with all submodules
git clone --recurse-submodules https://github.com/yapat-app/coral-annotation-tool.git
cd coral-annotation-tool

# Or if you already cloned without submodules:
git submodule update --init --recursive
```

### 2. Configure Environment Variables

Copy the example environment file and configure it:

```bash
cp .env.example .env
```

Edit `.env` and set your configuration, especially:
- `HF_ACCESS_TOKEN`: Your Hugging Face access token (get it from https://huggingface.co/settings/tokens)

### 3. Start All Services

```bash
# Build and start all services
docker-compose up -d

# View logs
docker-compose logs -f

# View logs for specific service
docker-compose logs -f coral-back
```

## Managing Services

### Stop All Services
```bash
docker-compose down
```

### Stop and Remove Volumes
```bash
docker-compose down -v
```

## Data Persistence

Data is persisted in the following locations:
- `./data`: Application data (datasets, images, etc.)
- `./coral-back/logs`: Backend logs
- `./coral-prompted-seg/weights`: Model weights for prompted segmentation
- `./coral-prompted-seg/logs`: Prompted segmentation logs
- `./coral-semantic-seg/logs`: Semantic segmentation logs
- `./coral-completion-seg/weights`: Model weights for completion segmentation
- `./coral-completion-seg/logs`: Completion segmentation logs

## Updating Submodules

To update all submodules to their latest versions:

```bash
# Update all submodules to latest commit on their tracked branch
git submodule update --remote

# Or update a specific submodule
git submodule update --remote coral-back
```

## Development

### Working on Individual Services

Each submodule is a separate git repository. To make changes:

```bash
# Navigate to the submodule
cd coral-back

# Create a branch and make changes
git checkout -b feature/my-feature
# ... make changes ...
git add .
git commit -m "My changes"
git push origin feature/my-feature

# Return to super repo
cd ..

# The super repo will show the submodule has changed
git status
git add coral-back
git commit -m "Update coral-back submodule"
```