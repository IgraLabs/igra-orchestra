# Multi-Platform Builds - Quick Guide

Build Docker images for both AMD64 and ARM64 architectures.

## Prerequisites

```bash
# Ensure SSH agent is running and has your GitHub key
ssh-add -l  # Should show your GitHub key
# If not, add it:
ssh-add ~/.ssh/id_rsa  # or your key path
```

## Setup Buildx

```bash
# Create and use a new builder instance
docker buildx create --name multiplatform --use

# Bootstrap the builder
docker buildx inspect --bootstrap
```

## Build & Push All Services (Multi-Platform)

```bash
# Login to Docker Hub
docker login

# Build and push each service with SSH forwarding
docker buildx build --platform linux/amd64,linux/arm64 \
  --ssh default \
  --tag igranetwork/block-builder:v0.2.2 \
  --file build/Dockerfile.block-builder \
  --push build/repos/block-builder

docker buildx build --platform linux/amd64,linux/arm64 \
  --ssh default \
  --tag igranetwork/viaduct:v0.2.2 \
  --file build/Dockerfile.viaduct \
  --push build/repos/viaduct

docker buildx build --platform linux/amd64,linux/arm64 \
  --ssh default \
  --tag igranetwork/rpc-provider:v0.2.1 \
  --file build/Dockerfile.rpc-provider \
  --push build/repos/igra-rpc-provider

docker buildx build --platform linux/amd64,linux/arm64 \
  --ssh default \
  --tag igranetwork/kaswallet:v0.2.1 \
  --file build/Dockerfile.kaswallet \
  --push build/repos/kaswallet
```
