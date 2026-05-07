# IQUANA Tool

A super repository that combines all services required for the IQUANA tool as git submodules.

## Overview

This repository orchestrates the following services:

- **frontend-react**: React frontend application (Port 4000)
- **backend**: Main backend API server (Port 4001)
- **prompted-seg-service**: Prompted segmentation service using SAM models (Port 4002)
- **semantic-seg-service**: Semantic/automatic segmentation service (Port 4003)
- **instance-discovery-service**: Completion segmentation service (Port 4004)
- **celery instances**: Task distribution queue for service that run long running tasks
- **redis**: Message broker for celery (Port 6379)

## Getting Started

### 1. Clone the Repository with Submodules

```bash
# Clone with all submodules
git clone --recurse-submodules https://github.com/Iquana-tool/iquana-tool.git
cd iquana-tool

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
docker-compose logs -f backend
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
- `./backend/logs`: Backend logs
- `./prompted-seg-service/weights`: Model weights for prompted segmentation
- `./prompted-seg-service/logs`: Prompted segmentation logs
- `./semantic-seg-service/logs`: Semantic segmentation logs
- `./instance-discovery-service/weights`: Model weights for completion segmentation
- `./instance-discovery-service/logs`: Completion segmentation logs

## Updating Submodules

To update all submodules to their latest versions:

```bash
# Update all submodules to latest commit on their tracked branch
git submodule update --remote

# Or update a specific submodule
git submodule update --remote backend
```

## Development

### Working on Individual Services

Each submodule is a separate git repository. To make changes:

```bash
# Navigate to the submodule
cd backend

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
git add backend
git commit -m "Update backend submodule"
```
