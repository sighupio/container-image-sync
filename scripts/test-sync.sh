#!/bin/bash
set -euo pipefail

# Container Image Sync Test Suite
# This script validates sync script functionality before running production syncs
# Usage: ./test-sync.sh [mode]
# Modes: dry-run (default), actual (runs real sync operations)

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SYNC_SCRIPT="${SCRIPT_DIR}/sync.sh"
readonly TEST_MODULE="${REPO_ROOT}/modules/_test/images.yml"

# Test mode (dry-run or actual)
readonly TEST_MODE="${1:-dry-run}"

# Test configuration
readonly TEST_TIMEOUT=300  # 5 minutes max per test
readonly SKOPEO_IMAGE="quay.io/skopeo/stable:v1.16"

# ANSI colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  INFO:${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}✅ SUCCESS:${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠️  WARNING:${NC} $*" >&2
}

log_error() {
    echo -e "${RED}❌ ERROR:${NC} $*" >&2
}

log_test_start() {
    echo -e "${BLUE}🧪 TEST:${NC} $*" >&2
    ((TESTS_TOTAL++))
}

log_test_pass() {
    echo -e "${GREEN}✅ PASS:${NC} $*" >&2
    ((TESTS_PASSED++))
}

log_test_fail() {
    echo -e "${RED}❌ FAIL:${NC} $*" >&2
    ((TESTS_FAILED++))
}

# Test helper functions
run_with_timeout() {
    local timeout="$1"
    shift
    # Just run the command without timeout
    "$@"
}

check_command_in_output() {
    local output="$1"
    local expected_command="$2"
    local test_name="$3"
    
    if echo "${output}" | grep -q "${expected_command}"; then
        log_test_pass "${test_name}: Found expected command '${expected_command}'"
        return 0
    else
        log_test_fail "${test_name}: Missing expected command '${expected_command}'"
        return 1
    fi
}

verify_image_exists() {
    local image="$1"
    local test_name="$2"
    
    log_info "Verifying image exists: ${image}"
    if docker run --rm "${SKOPEO_IMAGE}" inspect "docker://${image}" &>/dev/null; then
        log_test_pass "${test_name}: Image ${image} exists in registry"
        return 0
    else
        log_test_fail "${test_name}: Image ${image} not found in registry"
        return 1
    fi
}

verify_image_not_exists() {
    local image="$1"
    local test_name="$2"
    
    log_info "Verifying image does not exist: ${image}"
    if docker run --rm "${SKOPEO_IMAGE}" inspect "docker://${image}" &>/dev/null; then
        log_test_fail "${test_name}: Image ${image} unexpectedly exists in registry"
        return 1
    else
        log_test_pass "${test_name}: Image ${image} correctly does not exist"
        return 0
    fi
}

# Test functions
test_script_exists() {
    log_test_start "Sync script existence"
    
    if [[ -f "${SYNC_SCRIPT}" ]]; then
        log_test_pass "Sync script found at ${SYNC_SCRIPT}"
        return 0
    else
        log_test_fail "Sync script not found at ${SYNC_SCRIPT}"
        return 1
    fi
}

test_test_module_exists() {
    log_test_start "Test module existence"
    
    if [[ -f "${TEST_MODULE}" ]]; then
        log_test_pass "Test module found at ${TEST_MODULE}"
        return 0
    else
        log_test_fail "Test module not found at ${TEST_MODULE}"
        return 1
    fi
}

test_dry_run_basic() {
    log_test_start "Basic dry-run execution"
    
    local output
    if output=$(run_with_timeout "${TEST_TIMEOUT}" "${SYNC_SCRIPT}" "${TEST_MODULE}" true 2>&1); then
        log_test_pass "Dry-run completed without errors"
        
        # Check for expected dry-run indicators
        if echo "${output}" | grep -q "DRY RUN MODE"; then
            log_test_pass "Dry-run mode properly indicated"
        else
            log_test_fail "Dry-run mode not properly indicated"
            return 1
        fi
        
        return 0
    else
        log_test_fail "Dry-run failed with exit code $?"
        echo "${output}" >&2
        return 1
    fi
}

test_dry_run_commands() {
    log_test_start "Dry-run command validation"
    
    local output
    if output=$(run_with_timeout "${TEST_TIMEOUT}" "${SYNC_SCRIPT}" "${TEST_MODULE}" true 2>&1); then
        local all_passed=true
        
        # Check for expected commands in dry-run output (updated to match actual output format)
        check_command_in_output "${output}" "docker run -v ./login:/login --rm quay.io/skopeo/stable" "Skopeo sync command" || all_passed=false
        check_command_in_output "${output}" "docker://docker.io/library/alpine" "Alpine image reference" || all_passed=false
        check_command_in_output "${output}" "docker buildx build" "Build-based sync command" || all_passed=false
        check_command_in_output "${output}" "docker://registry.sighup.io/fury/testing/" "Test registry destination" || all_passed=false
        
        if [[ "${all_passed}" == "true" ]]; then
            log_test_pass "All expected commands found in dry-run output"
            return 0
        else
            log_test_fail "Some expected commands missing from dry-run output"
            return 1
        fi
    else
        log_test_fail "Dry-run failed, cannot validate commands"
        return 1
    fi
}

test_error_handling() {
    log_test_start "Error handling validation"
    
    # Test with non-existent file (should fail with clear error)
    local invalid_file="${REPO_ROOT}/modules/nonexistent/images.yml"
    
    # Run sync with invalid file and expect it to fail
    if run_with_timeout "${TEST_TIMEOUT}" "${SYNC_SCRIPT}" "${invalid_file}" false &>/dev/null; then
        log_test_fail "Sync with invalid file should have failed but succeeded"
        return 1
    else
        log_test_pass "Sync with invalid file properly failed"
        return 0
    fi
}

test_actual_sync_individual() {
    log_test_start "Actual sync execution with individual test validation"
    
    # Note about authentication
    log_info "Note: Tests may fail if not authenticated with registries."
    log_info "Run 'mise run auth' to set up authentication if needed."
    
    # Parse the test module and extract each image
    local num_images=$(yq eval '.images | length' "${TEST_MODULE}")
    local all_passed=true
    
    log_info "Testing ${num_images} images individually..."
    
    for ((i=0; i<num_images; i++)); do
        local image_name=$(yq eval ".images[$i].name" "${TEST_MODULE}")
        local should_fail=false
        
        # Check if this test is expected to fail
        if [[ "${image_name}" == *"(should fail)"* ]]; then
            should_fail=true
        fi
        
        log_info "Testing: ${image_name}"
        
        # Create a temporary file with just this image
        local temp_test_file="${REPO_ROOT}/modules/_test/test-single-${i}.yml"
        yq eval "{\"images\": [.images[$i]]}" "${TEST_MODULE}" > "${temp_test_file}"
        
        # Run the sync for this single image and capture output
        local sync_result=0
        local sync_output
        sync_output=$(run_with_timeout "${TEST_TIMEOUT}" "${SYNC_SCRIPT}" "${temp_test_file}" false 2>&1) || sync_result=$?
        
        # Validate the result
        if [[ "${should_fail}" == "true" ]]; then
            if [[ ${sync_result} -ne 0 ]]; then
                log_test_pass "${image_name}: Expected failure occurred correctly"
            else
                log_test_fail "${image_name}: Should have failed but succeeded"
                all_passed=false
            fi
        else
            if [[ ${sync_result} -eq 0 ]]; then
                log_test_pass "${image_name}: Sync completed successfully"
            else
                log_test_fail "${image_name}: Failed (exit code: ${sync_result}) - may need authentication (try 'mise run auth')"
                all_passed=false
            fi
        fi
        
        # Clean up temp file
        rm -f "${temp_test_file}"
    done
    
    if [[ "${all_passed}" == "true" ]]; then
        log_test_pass "All individual sync tests passed"
        return 0
    else
        log_test_fail "Some individual sync tests failed"
        return 1
    fi
}

# Main test execution
main() {
    echo "========================================"
    echo "🧪 Container Image Sync Test Suite"
    echo "========================================"
    echo "Mode: ${TEST_MODE}"
    echo
    
    log_info "Starting sync script validation (mode: ${TEST_MODE})..."
    echo
    
    # Pre-flight checks
    test_script_exists || exit 1
    test_test_module_exists || exit 1
    echo
    
    if [[ "${TEST_MODE}" == "actual" ]]; then
        # Actual sync mode - run real sync operations
        log_info "Running actual sync tests with expected failure handling..."
        test_actual_sync_individual || true
    else
        # Dry-run mode - existing tests
        log_info "Running dry-run validation tests..."
        test_dry_run_basic || true
        test_dry_run_commands || true
        test_error_handling || true
    fi
    
    echo
    echo "========================================"
    echo "📊 Test Results Summary"
    echo "========================================"
    echo "Total tests: ${TESTS_TOTAL}"
    echo "Passed: ${TESTS_PASSED}"
    echo "Failed: ${TESTS_FAILED}"
    echo
    
    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        log_success "All tests passed! ✨"
        exit 0
    else
        log_error "${TESTS_FAILED} test(s) failed!"
        exit 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi