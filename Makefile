.PHONY: help init up down restart logs build clean status shell

# Default target
help:
	@echo "Coral Annotation Tool - Docker Compose Management"
	@echo ""
	@echo "Available commands:"
	@echo "  make init       - Initialize submodules and create .env file"
	@echo "  make up         - Start all services"
	@echo "  make down       - Stop all services"
	@echo "  make restart    - Restart all services"
	@echo "  make logs       - View logs from all services"
	@echo "  make build      - Build all services"
	@echo "  make rebuild    - Rebuild and restart all services"
	@echo "  make clean      - Stop services and remove volumes"
	@echo "  make status     - Show status of all services"
	@echo "  make shell-back - Open shell in backend container"
	@echo "  make shell-front - Open shell in frontend-react container"
	@echo ""
	@echo "Service-specific commands:"
	@echo "  make up-front   - Start only frontend"
	@echo "  make up-back    - Start backend and AI services"
	@echo "  make logs-front - View frontend logs"
	@echo "  make logs-back  - View backend logs"
	@echo ""
	@echo "Git/Submodule commands:"
	@echo "  make update     - Update submodules to latest tracked branch"
	@echo "  make pull-all   - Pull latest from super repo and all submodules"
	@echo "  make pull-merge - Pull and merge (handles diverged branches)"
	@echo ""

# Initialize: Update submodules and create .env if it doesn't exist
init:
	@echo "Initializing submodules..."
	git submodule update --init --recursive
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env; \
		echo "⚠️  Please edit .env and set your HF_ACCESS_TOKEN"; \
	else \
		echo ".env already exists"; \
	fi

# Start all services
up:
	docker-compose up -d
	@echo ""
	@echo "✅ All services started!"
	@echo "Frontend: http://localhost:4000"
	@echo "Backend: http://localhost:4001"
	@echo "API Docs: http://localhost:4001/docs"

# Stop all services
down:
	docker-compose down

# Restart all services
restart:
	docker-compose restart

# View logs from all services
logs:
	docker-compose logs -f

# Build all services
build:
	DOCKER_BUILDKIT=1 docker-compose build

# Rebuild and restart all services
rebuild:
	DOCKER_BUILDKIT=1 docker-compose up -d --build

# Stop and remove volumes
clean:
	docker-compose down -v
	@echo "⚠️  All volumes removed. Data may be lost."

# Show status of all services
status:
	docker-compose ps

# Service-specific commands
up-front:
	docker-compose up -d frontend-react

up-back:
	docker-compose up -d backend

logs-front:
	docker-compose logs -f frontend-react

logs-back:
	docker-compose logs -f backend

logs-prompted:
	docker-compose logs -f prompted-seg-service

logs-semantic:
	docker-compose logs -f semantic-seg-service

logs-completion:
	docker-compose logs -f instance-discovery-service

# Open shell in containers
shell-back:
	docker-compose exec backend /bin/bash

shell-front:
	docker-compose exec frontend-react /bin/sh

shell-prompted:
	docker-compose exec prompted-seg-service /bin/bash

shell-semantic:
	docker-compose exec semantic-seg-service /bin/bash

shell-completion:
	docker-compose exec instance-discovery-service /bin/bash

# Update submodules to latest
update:
	@echo "Updating all submodules..."
	git submodule update --remote
	@echo "✅ Submodules updated"

# Pull latest changes from super repo and all submodules
pull-all:
	@echo "Pulling latest changes from super repo..."
	git pull origin main
	@echo ""
	@echo "Updating submodules to latest commits..."
	git submodule update --remote --recursive
	@echo ""
	@echo "Pulling latest changes in each submodule..."
	@for dir in backend frontend-react instance-discovery-service prompted-seg-service semantic-seg-service; do \
		if [ -d "$$dir" ]; then \
			echo "=== Pulling $$dir ==="; \
			cd $$dir && git pull origin $$(git branch --show-current 2>/dev/null || echo "main") && cd .. || true; \
		fi; \
	done
	@echo ""
	@echo "✅ All repositories updated"

# Pull and merge submodules (handles diverged branches)
pull-merge:
	@echo "Pulling latest changes from super repo..."
	git pull origin main
	@echo ""
	@echo "Pulling and merging in each submodule..."
	@for dir in backend frontend-react instance-discovery-service prompted-seg-service semantic-seg-service; do \
		if [ -d "$$dir" ]; then \
			echo "=== Pulling $$dir ==="; \
			cd $$dir && \
			branch=$$(git branch --show-current 2>/dev/null || echo "main") && \
			git pull origin $$branch --no-rebase 2>&1 | grep -v "Already up to date" || true && \
			cd ..; \
		fi; \
	done
	@echo ""
	@echo "✅ All repositories updated"
