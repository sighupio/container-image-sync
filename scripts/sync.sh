#!/bin/bash

# Container Image Sync Script
# 
# Synchronizes container images from source registries to destination registries
# supporting four different sync strategies:
#
# 1. Pull-based Multi-arch: Uses skopeo to copy multi-arch manifests
# 2. Pull-based Single-arch: Uses docker pull/tag/push for single platform images
# 3. Build-based Multi-arch: Uses docker buildx to build and push multi-arch images
# 4. Build-based Single-arch: Uses docker build for single platform custom images

set -euo pipefail

set +x

# Script configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CONFIG_FILE="${REPO_ROOT}/config/versions.yml"

# Error codes
readonly RC_ERROR_INVALID_CONFIG=2
readonly RC_ERROR_MISSING_TOOL=3

# Global configuration (loaded from config/versions.yml)
SKOPEO_IMAGE=""
YQ_VERSION=""
is_dry_run=false

# Progress tracking
total_images=0
current_image=0
synced_count=0
skipped_count=0
failed_count=0

# Colors for output (disabled if NO_COLOR is set or not in a terminal)
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly CYAN=''
    readonly BOLD=''
    readonly NC=''
fi

#######################################
# Unified logging function
#######################################

# Simple logging function without tree structure
log() {
    local level="$1"
    shift
    local message="$*"
    
    case "$level" in
        "info")     echo -e "ℹ️  ${BLUE}${message}${NC}" >&2 ;;
        "error")    echo -e "❌ ${RED}${message}${NC}" >&2 ;;
        "success")  echo -e "✅ ${GREEN}${message}${NC}" >&2 ;;
        "progress") echo -e "🔄 ${CYAN}${message}${NC}" >&2 ;;
        "skip")     echo -e "⏭️  ${PURPLE}${message}${NC}" >&2 ;;
        "debug")    
            if [[ "${DEBUG:-false}" == "true" ]]; then
                echo -e "🐛 ${message}" >&2
            fi
            ;;
    esac
}

# Tree-structured logging function with explicit tree characters
tree_log() {
    local level="$1"
    local tree_char="$2"
    local indent_level="$3"
    shift 3
    local message="$*"
    
    # Generate continuation indentation (│   ) for parent levels
    local indent=""
    for ((i=0; i<indent_level; i++)); do
        indent+="│   "
    done
    
    # Combine indentation with tree character
    local full_prefix="${indent}${tree_char}"
    
    case "$level" in
        "info")     echo -e "${full_prefix}${BLUE}${message}${NC}" >&2 ;;
        "error")    echo -e "${full_prefix}${RED}${message}${NC}" >&2 ;;
        "success")  echo -e "${full_prefix}${GREEN}${message}${NC}" >&2 ;;
        "progress") echo -e "${full_prefix}${CYAN}${message}${NC}" >&2 ;;
        "skip")     echo -e "${full_prefix}${PURPLE}${message}${NC}" >&2 ;;
        "debug")    
            if [[ "${DEBUG:-false}" == "true" ]]; then
                echo -e "${full_prefix}${message}" >&2
            fi
            ;;
    esac
}

# Helper function to run commands with clean indented output
run_with_indent() {
    local indent_level="$1"
    shift
    local command=("$@")
    
    # Generate clean continuation indentation without tree characters
    local cmd_indent=""
    for ((i=0; i<indent_level; i++)); do
        cmd_indent+="│   "
    done
    
    # Execute command and prefix each line with clean indentation
    # Capture exit status properly using exec redirection
    local temp_file=$(mktemp)
    
    # Execute command, capture output and exit status
    ("${command[@]}" 2>&1; echo $? > "$temp_file") | while IFS= read -r line; do
        echo -e "${cmd_indent}${line}" >&2
    done
    
    # Read and return the exit status
    local exit_status
    exit_status=$(cat "$temp_file")
    rm -f "$temp_file"
    
    return $exit_status
}

#######################################
# Configuration management
#######################################

load_configuration() {
    log info "Loading configuration from ${CONFIG_FILE}"
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log error "Configuration file not found: ${CONFIG_FILE}"
        exit ${RC_ERROR_INVALID_CONFIG}
    fi
    
    # Load tool versions from config
    SKOPEO_IMAGE="quay.io/skopeo/stable:$(yq e '.tools.skopeo' "${CONFIG_FILE}")"
    YQ_VERSION=$(yq e '.tools.yq' "${CONFIG_FILE}")
    
    log debug "Loaded configuration - Skopeo: ${SKOPEO_IMAGE}, yq: ${YQ_VERSION}"
}

validate_tools() {
    log info "Validating required tools"
    
    if ! command -v yq &> /dev/null; then
        log error "yq is not installed or not in PATH"
        exit ${RC_ERROR_MISSING_TOOL}
    fi
    
    if ! command -v docker &> /dev/null; then
        log error "docker is not installed or not in PATH"
        exit ${RC_ERROR_MISSING_TOOL}
    fi
    
    # Test skopeo availability
    if ! docker run --rm "${SKOPEO_IMAGE}" --version &> /dev/null; then
        log error "Unable to run skopeo image: ${SKOPEO_IMAGE}"
        exit ${RC_ERROR_MISSING_TOOL}
    fi
    
    log success "All required tools are available"
}

#######################################
# YAML configuration parsing
#######################################

parse_image_config() {
    local config_file="$1"
    local image_index="$2"
    local field="$3"
    
    yq e ".images[${image_index}].${field}" "${config_file}"
}

get_images_count() {
    local config_file="$1"
    yq e '.images | length' "${config_file}"
}

get_tags_count() {
    local config_file="$1"
    local image_index="$2"
    yq e ".images[${image_index}].tag | length" "${config_file}"
}

get_destinations_count() {
    local config_file="$1"
    local image_index="$2"
    yq e ".images[${image_index}].destinations | length" "${config_file}"
}

get_build_args_count() {
    local config_file="$1"
    local image_index="$2"
    yq e ".images[${image_index}].build.args | length" "${config_file}"
}

validate_image_config() {
    local config_file="$1"
    local image_index="$2"
    
    local destinations_count
    destinations_count=$(get_destinations_count "${config_file}" "${image_index}")
    
    if [[ ${destinations_count} -lt 1 ]]; then
        log error "Image at index ${image_index} has no destinations configured"
        exit ${RC_ERROR_INVALID_CONFIG}
    fi
}

#######################################
# Layer comparison for optimization
#######################################

check_layer_differences() {
    local source_image="$1"
    local destination_image="$2"
    local tag="$3"
    local multi_arch_enabled="$4"
    local dry_run="${5:-false}"
    
    tree_log debug "├── " 2 "Checking layer differences for ${source_image}:${tag}"
    
    # Variables to track layer differences (1 = different, 0 = same)
    local layer_diff_amd64=1
    local layer_diff_arm64=1
    
    if [[ "${dry_run}" == "true" ]]; then
        tree_log info "├── " 2 "🏃 DRY RUN: Would check layer differences"
        tree_log info "├── " 3 "docker run --rm ${SKOPEO_IMAGE} inspect -n --override-os linux --override-arch amd64 docker://${source_image}:${tag}"
        tree_log info "├── " 3 "docker run --rm ${SKOPEO_IMAGE} inspect -n --override-os linux --override-arch amd64 docker://${destination_image}:${tag}"
        
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            tree_log info "├── " 3 "docker run --rm ${SKOPEO_IMAGE} inspect -n --override-os linux --override-arch arm64 docker://${source_image}:${tag}"
            tree_log info "└── " 3 "docker run --rm ${SKOPEO_IMAGE} inspect -n --override-os linux --override-arch arm64 docker://${destination_image}:${tag}"
        fi
        
        echo "1 1" # Return "different" for dry run to show what would be synced
        return
    fi
    
    
    # Check AMD64 layers
    local source_layers_amd64
    local destination_layers_amd64
    
    source_layers_amd64=$(docker run --rm "${SKOPEO_IMAGE}" inspect -n --override-os linux --override-arch amd64 "docker://${source_image}:${tag}" 2> /dev/null | yq .Layers) || true
    destination_layers_amd64=$(docker run --rm "${SKOPEO_IMAGE}" inspect -n --override-os linux --override-arch amd64 "docker://${destination_image}:${tag}" 2> /dev/null | yq .Layers) || true
    
    if [[ "${destination_layers_amd64}" != "null" && -n "${destination_layers_amd64}" ]]; then
        if diff <(echo "${source_layers_amd64}") <(echo "${destination_layers_amd64}") > /dev/null; then
            layer_diff_amd64=0
        fi
    fi
    
    # Show simplified comparison result
    if [[ ${layer_diff_amd64} -eq 0 ]]; then
        tree_log info "├── " 2 "🔍 Comparing ${source_image}:${tag} layers: AMD64 identical ✓"
    else
        tree_log info "├── " 2 "🔍 Comparing ${source_image}:${tag} layers: AMD64 different ✗"
    fi
    
    # For single-arch images, ARM64 diff is the same as AMD64
    layer_diff_arm64=${layer_diff_amd64}
    
    # Check ARM64 layers if multi-arch is enabled
    if [[ "${multi_arch_enabled}" == "true" ]]; then
        local source_layers_arm64
        local destination_layers_arm64
        
        source_layers_arm64=$(docker run --rm "${SKOPEO_IMAGE}" inspect -n --override-os linux --override-arch arm64 "docker://${source_image}:${tag}" 2> /dev/null | yq .Layers) || true
        destination_layers_arm64=$(docker run --rm "${SKOPEO_IMAGE}" inspect -n --override-os linux --override-arch arm64 "docker://${destination_image}:${tag}" 2> /dev/null | yq .Layers) || true
        
        if [[ "${destination_layers_arm64}" != "null" && -n "${destination_layers_arm64}" ]]; then
            if diff <(echo "${source_layers_arm64}") <(echo "${destination_layers_arm64}") > /dev/null; then
                layer_diff_arm64=0
            fi
        fi
        
        # Show ARM64 comparison result
        if [[ ${layer_diff_arm64} -eq 0 ]]; then
            tree_log info "├── " 2 "🔍 Comparing ${source_image}:${tag} layers: ARM64 identical ✓"
        else
            tree_log info "├── " 2 "🔍 Comparing ${source_image}:${tag} layers: ARM64 different ✗"
        fi
    fi
    
    # Return both diff results
    echo "${layer_diff_amd64} ${layer_diff_arm64}"
}

#######################################
# Sync strategy determination and execution
#######################################

determine_sync_strategy() {
    local build_context="$1"
    local multi_arch_enabled="$2"
    
    # Strategy determination:
    # - If build_context is "null", it's a pull-based sync
    # - If build_context is set, it's a build-based sync
    # - Multi-arch flag determines the tool used (skopeo/buildx vs docker)
    
    if [[ "${build_context}" == "null" ]]; then
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            echo "pull-multi-arch"
        else
            echo "pull-single-arch"
        fi
    else
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            echo "build-multi-arch"
        else
            echo "build-single-arch"
        fi
    fi
}

sync_pull_based_image() {
    local source_image="$1"
    local tag="$2"
    local multi_arch_enabled="$3"
    local dry_run="${4:-false}"
    
    if [[ "${dry_run}" == "true" ]]; then
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            tree_log info "├── " 2 "🏃 DRY RUN: Would use skopeo for multi-arch (no local pull needed)"
        else
            tree_log info "├── " 2 "🏃 DRY RUN: Would pull ${source_image}:${tag} (single-arch)"
            tree_log info "└── " 3 "docker pull ${source_image}:${tag}"
        fi
        return 0
    fi
    
    if [[ "${multi_arch_enabled}" == "true" ]]; then
        tree_log info "├── " 2 "📦 Using skopeo for multi-arch pull (no local pull needed)"
    else
        tree_log progress "├── " 2 "📥 Pulling ${source_image}:${tag}"
        run_with_indent 4 docker pull "${source_image}:${tag}"
    fi
}

sync_build_based_image() {
    local config_file="$1"
    local image_index="$2"
    local source_image="$3"
    local tag="$4"
    local build_context="$5"
    local multi_arch_enabled="$6"
    local first_destination="$7"
    local dry_run="${8:-false}"
    
    if [[ "${multi_arch_enabled}" == "true" ]]; then
        tree_log progress "├── " 2 "🔨 Building ${first_destination}:${tag} from context: ${build_context} (multi-arch)"
    else
        tree_log progress "├── " 2 "🔨 Building ${source_image}:${tag} from context: ${build_context} (single-arch)"
    fi
    
    # Process build arguments
    local build_args=""
    local build_args_count
    build_args_count=$(get_build_args_count "${config_file}" "${image_index}")
    
    for (( arg_index=0; arg_index<build_args_count; arg_index++ )); do
        local arg_name
        local arg_value
        arg_name=$(yq e ".images[${image_index}].build.args[${arg_index}].name" "${config_file}")
        arg_value=$(yq e ".images[${image_index}].build.args[${arg_index}].value" "${config_file}")
        build_args="${build_args} --build-arg ${arg_name}=${arg_value}"
    done
    
    local context_path="$(dirname "${config_file}")/${build_context}"
    
    if [[ "${dry_run}" == "true" ]]; then
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            tree_log info "├── " 2 "🏃 DRY RUN: Would build multi-arch image to ${first_destination}:${tag}"
            tree_log info "├── " 3 "docker buildx build --push \\"
            tree_log info "├── " 3 "       --platform linux/amd64,linux/arm64 \\"
            if [[ -n "${build_args}" ]]; then
                tree_log info "├── " 3 "       ${build_args} --build-arg IMAGETAG=${tag} \\"
            else
                tree_log info "├── " 3 "       --build-arg IMAGETAG=${tag} \\"
            fi
            tree_log info "└── " 3 "       -t ${first_destination}:${tag} ${context_path}"
        else
            tree_log info "├── " 2 "🏃 DRY RUN: Would build single-arch image ${source_image}:${tag}"
            tree_log info "├── " 3 "docker build${build_args} --build-arg IMAGETAG=${tag} \\"
            tree_log info "└── " 3 "       -t ${source_image}:${tag} ${context_path}"
        fi
        return 0
    fi
    
    if [[ "${multi_arch_enabled}" == "true" ]]; then
        local target_image="${first_destination}:${tag}"
        tree_log info "├── " 2 "🏗️  Building multi-arch image to ${target_image} with buildx"
        
        run_with_indent 4 docker buildx build --push \
            --platform linux/amd64,linux/arm64 \
            ${build_args} --build-arg IMAGETAG="${tag}" \
            -t "${target_image}" "${context_path}"
    else
        tree_log info "├── " 2 "🏗️  Building single-arch image ${source_image}:${tag}"
        run_with_indent 4 docker build ${build_args} --build-arg IMAGETAG="${tag}" \
            -t "${source_image}:${tag}" "${context_path}"
    fi
}

process_destinations() {
    local config_file="$1"
    local image_index="$2"
    local source_image="$3"
    local tag="$4"
    local multi_arch_enabled="$5"
    local build_context="$6"
    local destinations_count="$7"
    local dry_run="${8:-false}"
    
    tree_log debug "├── " 2 "Processing ${destinations_count} destinations"
    
    for (( dest_index=0; dest_index<destinations_count; dest_index++ )); do
        local destination_image
        destination_image=$(yq e ".images[${image_index}].destinations[${dest_index}]" "${config_file}")
        local destination_tag="${destination_image}:${tag}"
        
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            # For multi-arch builds, the first destination is the build target
            if [[ "${build_context}" != "null" && ${dest_index} -eq 0 ]]; then
                if [[ "${dry_run}" == "true" ]]; then
                    tree_log info "├── " 3 "🏃 DRY RUN: First destination ${destination_tag} (already built)"
                else
                    tree_log debug "├── " 3 "⏭️  Skipping first destination (already built to this target)"
                fi
                continue
            elif [[ "${build_context}" != "null" && ${dest_index} -gt 0 ]]; then
                # For subsequent destinations, use the first destination as source
                local first_destination
                first_destination=$(yq e ".images[${image_index}].destinations[0]" "${config_file}")
                source_image="${first_destination}"
            fi
            
            if [[ "${dry_run}" == "true" ]]; then
                tree_log info "├── " 3 "🏃 DRY RUN: Would sync ${source_image}:${tag} → ${destination_tag} (multi-arch)"
                tree_log info "├── " 4 "docker run -v ./login:/login --rm ${SKOPEO_IMAGE} \\"
                tree_log info "├── " 4 "       copy --authfile=/login/auth.json --multi-arch all \\"
                tree_log info "├── " 4 "       docker://${source_image}:${tag} \\"
                tree_log info "└── " 4 "       docker://${destination_tag}"
            else
                tree_log progress "├── " 3 "📤 Syncing ${source_image}:${tag} → ${destination_tag} (multi-arch)"
                run_with_indent 5 docker run -v ./login:/login \
                    --rm \
                    "${SKOPEO_IMAGE}" \
                    copy --authfile=/login/auth.json --multi-arch all \
                    "docker://${source_image}:${tag}" "docker://${destination_tag}"
            fi
        else
            if [[ "${dry_run}" == "true" ]]; then
                tree_log info "├── " 3 "🏃 DRY RUN: Would sync ${source_image}:${tag} → ${destination_tag} (single-arch)"
                tree_log info "├── " 4 "docker tag ${source_image}:${tag} ${destination_tag}"
                tree_log info "├── " 4 "docker push ${destination_tag}"
                tree_log info "└── " 4 "docker rmi ${destination_tag}"
            else
                tree_log progress "├── " 3 "📤 Syncing ${source_image}:${tag} → ${destination_tag} (single-arch)"
                run_with_indent 5 docker tag "${source_image}:${tag}" "${destination_tag}"
                run_with_indent 5 docker push "${destination_tag}"
                run_with_indent 5 docker rmi "${destination_tag}"
            fi
        fi
    done
}

cleanup_local_images() {
    local source_image="$1"
    local tag="$2"
    local multi_arch_enabled="$3"
    local dry_run="${4:-false}"
    
    if [[ "${dry_run}" == "true" ]]; then
        if [[ "${multi_arch_enabled}" == "true" ]]; then
            tree_log info "├── " 2 "🏃 DRY RUN: No cleanup needed (skopeo, no local image)"
        else
            tree_log info "├── " 2 "🏃 DRY RUN: Would clean up ${source_image}:${tag}"
            tree_log info "└── " 3 "docker rmi ${source_image}:${tag}"
        fi
        return 0
    fi
    
    if [[ "${multi_arch_enabled}" == "true" ]]; then
        tree_log debug "├── " 2 "🧹 Skipping image cleanup (using skopeo, no local image)"
    else
        tree_log debug "├── " 2 "🧹 Cleaning up local image ${source_image}:${tag}"
        run_with_indent 4 docker rmi "${source_image}:${tag}" || true
    fi
}

#######################################
# Main sync processing logic
#######################################

process_single_image() {
    local config_file="$1"
    local image_index="$2"
    
    # Extract image configuration
    local image_name
    local source_image
    local build_context
    local multi_arch_enabled
    local destinations_count
    local tags_count
    
    image_name=$(parse_image_config "${config_file}" "${image_index}" "name")
    source_image=$(parse_image_config "${config_file}" "${image_index}" "source")
    build_context=$(parse_image_config "${config_file}" "${image_index}" "build.context")
    multi_arch_enabled=$(parse_image_config "${config_file}" "${image_index}" "multi-arch")
    destinations_count=$(get_destinations_count "${config_file}" "${image_index}")
    tags_count=$(get_tags_count "${config_file}" "${image_index}")
    
    # Set default multi-arch value if null or empty
    if [[ "${multi_arch_enabled}" == "null" || -z "${multi_arch_enabled}" ]]; then
        multi_arch_enabled="true"
    fi
    
    # Validate configuration
    validate_image_config "${config_file}" "${image_index}"
    
    # Get first destination for build-based sync
    local first_destination
    first_destination=$(yq e ".images[${image_index}].destinations[0]" "${config_file}")
    
    current_image=$((current_image + 1))
    tree_log info "├── " 0 "📦 ${BOLD}${image_name}${NC} (${current_image}/${total_images})"
    
    # Show source → destination mapping for clarity
    if [[ "${destinations_count}" -gt 1 ]]; then
        tree_log info "├── " 1 "Source: ${source_image} → ${destinations_count} destinations"
    else
        tree_log info "├── " 1 "Source: ${source_image} → ${first_destination}"
    fi
    
    tree_log debug "├── " 1 "Details: Multi-arch: ${multi_arch_enabled}, Context: ${build_context}"
    
    # Determine sync strategy
    local sync_strategy
    sync_strategy=$(determine_sync_strategy "${build_context}" "${multi_arch_enabled}")
    tree_log debug "├── " 1 "Strategy: ${sync_strategy}"
    
    # Process each tag
    for (( tag_index=0; tag_index<tags_count; tag_index++ )); do
        local tag
        tag=$(yq e ".images[${image_index}].tag[${tag_index}]" "${config_file}")
        
        tree_log info "├── " 1 "🏷️  ${tag} ($((tag_index + 1))/${tags_count})"
        
        # Layer comparison optimization (only for pull-based sync)
        local should_sync=true
        if [[ "${build_context}" == "null" ]]; then
            local layer_diff_results
            layer_diff_results=$(check_layer_differences "${source_image}" "${first_destination}" "${tag}" "${multi_arch_enabled}" "${is_dry_run}")
            
            local layer_diff_amd64 layer_diff_arm64
            read -r layer_diff_amd64 layer_diff_arm64 <<< "${layer_diff_results}"
            
            if [[ ${layer_diff_amd64} -eq 0 && ${layer_diff_arm64} -eq 0 && "${is_dry_run}" == "false" ]]; then
                tree_log skip "└── " 2 "⏭️  Already synced ${source_image}:${tag} → ${first_destination}:${tag} (layers match)"
                skipped_count=$((skipped_count + 1))
                should_sync=false
            fi
        fi
        
        if [[ "${should_sync}" == "true" ]]; then
            # Capture errors instead of exiting
            set +e
            local sync_result=0
            
            case "${sync_strategy}" in
                "pull-multi-arch"|"pull-single-arch")
                    sync_pull_based_image "${source_image}" "${tag}" "${multi_arch_enabled}" "${is_dry_run}"
                    sync_result=$?
                    ;;
                "build-multi-arch"|"build-single-arch")
                    sync_build_based_image "${config_file}" "${image_index}" "${source_image}" "${tag}" "${build_context}" "${multi_arch_enabled}" "${first_destination}" "${is_dry_run}"
                    sync_result=$?
                    ;;
            esac
            
            # Only process destinations and cleanup if sync was successful
            if [[ ${sync_result} -eq 0 ]]; then
                process_destinations "${config_file}" "${image_index}" "${source_image}" "${tag}" "${multi_arch_enabled}" "${build_context}" "${destinations_count}" "${is_dry_run}"
                sync_result=$?
                
                if [[ ${sync_result} -eq 0 ]]; then
                    cleanup_local_images "${source_image}" "${tag}" "${multi_arch_enabled}" "${is_dry_run}"
                fi
            fi
            
            # Report result with context
            if [[ ${sync_result} -eq 0 ]]; then
                if [[ "${is_dry_run}" == "true" ]]; then
                    tree_log success "└── " 2 "✅ Would sync ${source_image}:${tag} → ${destinations_count} destination(s)"
                else
                    tree_log success "└── " 2 "✅ Synced ${source_image}:${tag} → ${destinations_count} destination(s)"
                fi
                synced_count=$((synced_count + 1))
            else
                tree_log error "└── " 2 "❌ Failed to sync ${source_image}:${tag} → ${destinations_count} destination(s)"
                failed_count=$((failed_count + 1))
            fi
            
            # Restore error handling
            set -e
        fi
    done
    
    tree_log success "└── " 0 "✅ Completed ${image_name}"
}

print_summary() {
    echo
    log info "📊 Sync Summary"
    log info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log info "  Total images:    ${total_images}"
    log success "  ✅ Synced:       ${synced_count}"
    log skip "  ⏭️  Skipped:      ${skipped_count}"
    log error "  ❌ Failed:       ${failed_count}"
    log info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ "${is_dry_run}" == "true" ]]; then
        log info "🏃 This was a dry run - no actual changes were made"
    fi
}

#######################################
# Main entry point
#######################################

usage() {
    cat << EOF
Usage: $0 <config_file> <dry_run>

Container Image Sync Script - Synchronizes images from source to destination registries

Arguments:
  config_file    Path to YAML configuration file (e.g., modules/auth/images.yml)
  dry_run        Set to 'true' for dry run mode, 'false' for actual sync

Examples:
  $0 modules/auth/images.yml true     # Dry run mode
  $0 modules/auth/images.yml false    # Actual sync

Environment Variables:
  DEBUG=true     Enable debug logging
  NO_COLOR=true  Disable colored output

EOF
}

main() {
    # Parse command line arguments
    if [[ $# -ne 2 ]]; then
        log error "Invalid number of arguments"
        usage
        exit 1
    fi
    
    local config_file="$1"
    local dry_run_input="$2"
    
    # Validate arguments
    if [[ ! -f "${config_file}" ]]; then
        log error "Configuration file not found: ${config_file}"
        exit 1
    fi
    
    if [[ "${dry_run_input}" == "true" ]]; then
        is_dry_run=true
        log info "🏃 DRY RUN MODE ENABLED"
    elif [[ "${dry_run_input}" == "false" ]]; then
        is_dry_run=false
        log info "🚀 PRODUCTION SYNC MODE"
    else
        log error "Invalid dry_run value: ${dry_run_input}. Must be 'true' or 'false'"
        exit 1
    fi
    
    # Initialize
    load_configuration
    validate_tools
    
    # Calculate total work
    total_images=$(get_images_count "${config_file}")
    log info "📋 Processing ${total_images} images from ${config_file}"
    
    # Process all images
    log info "📦 Container Image Sync"
    log info "├── Configuration: ${config_file}"
    if [[ "${is_dry_run}" == "true" ]]; then
        log info "├── Mode: 🏃 Dry Run"
    else
        log info "├── Mode: 🚀 Production"
    fi
    log info "└── Images to process: ${total_images}"
    echo
    
    for (( image_index=0; image_index<total_images; image_index++ )); do
        if ! process_single_image "${config_file}" "${image_index}"; then
            failed_count=$((failed_count + 1))
            log error "Failed to process image at index ${image_index}"
        fi
    done
    
    # Print final summary
    print_summary
    
    # Exit with appropriate code
    if [[ ${failed_count} -gt 0 ]]; then
        exit 1
    fi
}

# Run main function with all arguments
main "$@"