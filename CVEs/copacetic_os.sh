#!/bin/bash

# OS specific handling of the Copacetic patching, used by patch_images_with_copacetic.sh.
#
# Copa patches distroless Debian images with the apt of a Debian tooling image, chosen by Copa itself
# (debian:stable-slim for Debian 12+). The tooling image must be of the same Debian release of the image
# to patch: Copa downloads the packages without a version and accepts any newer one, so with the apt
# sources of a newer release the patched image gets packages of that release and can break. The BuildKit
# source policy of the image's release (copacetic-source-policy.<release>.json) redirects the tooling
# image to our helper with the apt sources of that release only (see MAINTENANCE.md).
#
# Images of the other OSes are patched with their own package manager: nothing to do.

COPACETIC_SOURCE_POLICY_DIR="${COPACETIC_SOURCE_POLICY_DIR:-$(dirname ${BASH_SOURCE[0]})}"

# Prints the BuildKit source policy to patch the image of the trivy report with (nothing if not needed).
# Fails printing the reason when the image can't be patched safely.
function source_policy_for() {
  local trivy_report="$1" debian_major debian_release
  [ "$(jq -r '.Metadata.OS.Family // empty' "${trivy_report}")" != "debian" ] && return 0

  # Copa chooses the Debian tooling image from the same trivy field
  debian_major=$(jq -r '.Metadata.OS.Name // empty' "${trivy_report}" | cut -d. -f1)
  case "${debian_major}" in
    12) debian_release=bookworm ;;
    13) debian_release=trixie ;;
    # Copa uses debian:<major>-slim, of the same release of the image
    [0-9]|1[01]) return 0 ;;
    *) echo "no copacetic source policy for debian '${debian_major}'" && return 1 ;;
  esac
  [ ! -f "${COPACETIC_SOURCE_POLICY_DIR}/copacetic-source-policy.${debian_release}.json" ] \
    && echo "missing copacetic source policy for debian ${debian_release}" && return 1
  echo "${COPACETIC_SOURCE_POLICY_DIR}/copacetic-source-policy.${debian_release}.json"
}

# Prints the dpkg packages (name=version) of an image, from /var/lib/dpkg/status and from
# /var/lib/dpkg/status.d (distroless images), then its Debian major version from /etc/os-release
# (when present) as os-release=<VERSION_ID>
function debian_image_packages() {
  local image="$1" dir container
  dir=$(mktemp -d)
  # the command is never run, it is only required to create a container from images without one
  if ! container=$(docker create "${image}" true 2> /dev/null)
  then
    rm -rf "${dir}"
    return 1
  fi
  docker cp "${container}:/var/lib/dpkg" "${dir}/dpkg" > /dev/null 2>&1
  # /etc/os-release is usually a symlink to ../usr/lib/os-release: -L copies the file it points to
  docker cp -L "${container}:/etc/os-release" "${dir}/os-release" > /dev/null 2>&1
  docker rm "${container}" > /dev/null
  cat "${dir}"/dpkg/status "${dir}"/dpkg/status.d/* 2> /dev/null \
    | awk '/^Package:/ { package=$2 } /^Version:/ { print package "=" $2 }' | sort -u
  sed -n 's/^VERSION_ID="\{0,1\}\([0-9]*\).*/os-release=\1/p' "${dir}/os-release" 2> /dev/null
  rm -rf "${dir}"
}

# Prints the problems of the patched image, compared with the original one of the trivy report (nothing
# if it can be pushed): for Debian, an original /etc/os-release of another Debian version than the trivy
# one used to choose the source policy (an independent check of the trivy detection), and the packages
# added or updated by the patch that belong to another Debian release (debN in the version), whatever
# tooling image Copa used
function patched_image_problems() {
  local trivy_report="$1" original_image="$2" patched_image="$3" debian_major original_packages patched_packages
  [ "$(jq -r '.Metadata.OS.Family // empty' "${trivy_report}")" != "debian" ] && return 0

  debian_major=$(jq -r '.Metadata.OS.Name // empty' "${trivy_report}" | cut -d. -f1)
  if ! original_packages=$(debian_image_packages "${original_image}")
  then
    echo "can't read the packages of ${original_image}"
    return
  fi
  if ! patched_packages=$(debian_image_packages "${patched_image}")
  then
    echo "can't read the packages of ${patched_image}"
    return
  fi
  grep '^os-release=' <<< "${original_packages}" | grep -v -q "^os-release=${debian_major}$" \
    && echo "/etc/os-release of the original image is not debian ${debian_major}"
  updated_packages=$(comm -13 <(grep -v '^os-release=' <<< "${original_packages}") <(grep -v '^os-release=' <<< "${patched_packages}"))
  awk -F= -v release="deb${debian_major}" '{ if (match($2, /deb[0-9]+/) && substr($2, RSTART, RLENGTH) != release) printf "%s ", $0 }' <<< "${updated_packages}"
  # logged on stderr, the problems are the output
  info "checked $(grep -c . <<< "${updated_packages}") packages added or updated by the patch for debian ${debian_major} ($(grep '^os-release=' <<< "${original_packages}" || echo 'os-release=missing')): ${updated_packages//[$'\r\n']/ }" >&2
}
