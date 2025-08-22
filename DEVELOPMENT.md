# Development Guide

This guide covers local development setup, testing, and troubleshooting for the container image sync system.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with buildx support
- [mise](https://mise.jdx.dev/) for tool management
- Access to the SIGHUP registry (for actual sync testing)

## Quick Setup

1. **Install tools**:
   ```bash
   mise install
   ```

2. **Setup Docker buildx for multi-platform builds (matches CI environment)**:
   ```bash
   mise run setup-buildx
   ```

3. **Set up SIGHUP registry authentication for local testing**:
   ```bash
   mise run auth
   ```

## Testing

### Dry Run Testing
Test the sync logic without making any changes:

```bash
# Run sync in dry-run mode (uses test module)
mise run dry-run

# Test specific modules in dry-run mode
mise run sync modules/auth/images.yml true
```

### Actual Sync Testing
Test real synchronization (requires authentication):

```bash
# Run actual sync tests with expected failure handling
mise run test-actual

# Manual sync testing (actual sync mode)
mise run sync modules/_test/images.yml false
```

### Validation Testing
Run the full test suite (used in CI):

```bash
# Run sync script tests
mise run test
```

## Development Workflow

### Local Testing Setup

1. **Prepare environment**:
   ```bash
   # Setup Docker buildx for multi-platform builds (one-time setup)
   mise run setup-buildx
   
   # Set up SIGHUP registry authentication for local testing
   mise run auth
   ```

2. **Test your changes**:
   ```bash
   # Run sync in dry-run mode (quick validation)
   mise run dry-run
   
   # Run actual sync tests with expected failure handling
   mise run test-actual
   ```

### Sync Script Architecture

The main sync script (`scripts/sync.sh`) supports four sync strategies:

- **Pull-based Single-arch**: Uses `docker pull/tag/push` for single-platform images
- **Pull-based Multi-arch**: Uses `skopeo copy --multi-arch all` for multi-platform manifests  
- **Build-based Single-arch**: Uses `docker build` for custom single-platform builds
- **Build-based Multi-arch**: Uses `docker buildx build --platform` for multi-platform builds

### Configuration Format

Each module contains an `images.yml` file with this structure:

```yaml
images:
  - name: "Human-readable name"
    source: "source/image"           # Source image or build target name
    multi-arch: true                 # Optional, defaults to true
    build:                          # Optional, for build-based sync
      context: "custom/build-dir"
      args:
        - name: "BUILD_ARG"
          value: "value"
    tag:
      - "1.0.0"
      - "latest"
    destinations:
      - "registry.sighup.io/fury/module/image"
```

## Troubleshooting

### macOS Multi-Platform Build Issues

**Error**: `Multi-platform build is not supported for the docker driver`

**Solution**: Run the buildx setup task:
```bash
mise run setup-buildx
```

This creates a `docker-container` driver that supports multi-platform builds, matching the CI environment.

### Authentication Issues

**Error**: Registry authentication failures

**Solution**:
1. Ensure you have valid SIGHUP registry credentials
2. Set up SIGHUP registry authentication: `mise run auth`
3. Verify login: `docker login registry.sighup.io`

### Layer Comparison Optimization

The sync script compares image layers before syncing to skip images that are already up-to-date. This optimization:

- Only applies to pull-based sync (not build-based)
- Compares both AMD64 and ARM64 layers for multi-arch images
- Shows comparison results in the logs: `🔍 AMD64 layer comparison result: 0 (0=same, 1=different)`

### Expected Test Failures

The test module (`modules/_test/`) includes scenarios that should fail:

- **Invalid source images**: Tests error handling for non-existent images
- **Missing build contexts**: Tests build failure handling
- **Multi-platform buildx requirements**: May fail without proper buildx setup

These failures are expected and handled properly by the test framework.

## Available Tasks

### Setup and Authentication
Run these once to prepare your environment:

```bash
# Setup Docker buildx for multi-platform builds (matches CI environment)
mise run setup-buildx

# Set up SIGHUP registry authentication for local testing  
mise run auth
```

### Testing
Choose the appropriate test for your needs:

```bash
# Run sync script tests (validation only, used in CI)
mise run test

# Run actual sync tests with expected failure handling (requires auth)
mise run test-actual

# Run sync in dry-run mode (preview commands without changes)
mise run dry-run
```

### Manual Sync
For testing specific modules:

```bash
# Run sync for a module
mise run sync <module-path> [dry-run-boolean]

# Examples:
mise run sync modules/auth/images.yml true     # Dry-run mode
mise run sync modules/auth/images.yml false    # Actual sync (requires auth)
```

**Typical workflow**: `setup-buildx` → `auth` → `test-actual` or `dry-run`

## CI Integration

The GitHub Actions workflow:

1. **Test Phase**: Runs comprehensive script validation
2. **Discovery Phase**: Identifies modules to sync
3. **Sync Phase**: Processes each module in parallel
4. **Summary Phase**: Reports results

The local testing environment matches the CI environment through:
- Same Docker buildx setup
- Same authentication methods
- Same test scenarios and expected behaviors

## File Structure

```
├── config/versions.yml           # Tool version management
├── scripts/
│   ├── sync.sh                   # Main synchronization script
│   └── test-sync.sh             # Test validation script
├── modules/
│   ├── _test/                   # Test scenarios
│   └── <module>/images.yml      # Module configurations
├── .github/
│   ├── workflows/               # CI/CD workflows
│   └── actions/                # Reusable composite actions
└── mise.toml                   # Development task definitions
```