# Test Module for Container Image Sync

This is a special test module designed to validate the sync script functionality before running any production sync operations.

## Test Scenarios

### Success Scenarios (Should Work)
1. **Pull-based single-arch**: Tests basic image pulling with alpine:3.18
2. **Pull-based multi-arch**: Tests multi-architecture image handling with alpine:3.19
3. **Build-based single-arch**: Tests custom image building with simple Dockerfile
4. **Build-based multi-arch**: Tests multi-arch custom image building

### Error Scenarios (Should Fail Gracefully)
1. **Invalid source image**: Tests error handling for non-existent images
2. **Missing build context**: Tests error handling for invalid Dockerfile paths

## Test Registry Namespace

All test images are synced to: `registry.sighup.io/fury/testing/`

This namespace is separate from production images to avoid interference.

## Usage in CI

This test module runs automatically in CI before any other sync operations:
- If tests pass: Normal sync operations proceed
- If tests fail: Entire workflow is stopped to prevent issues

## Local Testing

```bash
# Test dry-run mode
./scripts/sync.sh modules/_test/images.yml true

# Test actual sync (requires registry authentication)
./scripts/sync.sh modules/_test/images.yml false
```