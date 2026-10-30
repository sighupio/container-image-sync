#!/bin/bash

# Checks the Copacetic helper images used by the source policies (copacetic-source-policy.<release>.json);
# each helper must exist for amd64 and arm64 and be a Debian <release> image with the apt sources of
# <release> only, otherwise Copa would patch the images with packages of another Debian release

source $(dirname $0)/logging.sh

RETURN_ERROR=0

for policy in $(dirname $0)/copacetic-source-policy.*.json
do
  release=$(basename "${policy}" .json)
  release=${release#copacetic-source-policy.}
  helpers=$(jq -r '.rules[] | select(.action == "CONVERT") | .updates.identifier | sub("^docker-image://"; "")' "${policy}" | sort -u)
  [[ -z "${helpers}" ]] && error "${policy}: no helper image" && RETURN_ERROR=$((RETURN_ERROR + 1))

  for helper in ${helpers}
  do
    architectures=$(docker manifest inspect "${helper}" 2> /dev/null | jq -r '[.manifests[]?.platform.architecture] | join(" ")')
    if [[ ! " ${architectures} " =~ " amd64 " ]] || [[ ! " ${architectures} " =~ " arm64 " ]]
    then
      error "${policy}: helper ${helper} not found for amd64 and arm64 (found: ${architectures})"
      RETURN_ERROR=$((RETURN_ERROR + 1))
      continue
    fi

    if ! helper_info=$(docker run --rm --entrypoint sh "${helper}" -c \
      '. /etc/os-release; echo "codename=${VERSION_CODENAME}"; cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2> /dev/null; true')
    then
      error "${policy}: can't run helper ${helper}"
      RETURN_ERROR=$((RETURN_ERROR + 1))
      continue
    fi
    codename=$(sed -n 's/^codename=//p' <<< "${helper_info}")
    # suites of the apt sources, both in deb822 format, from the Suites field, and in one-line format, from the third field of the deb lines
    suites=$(awk '/^Suites:/ { for (i = 2; i <= NF; i++) print $i }
      /^deb / { sub(/\[[^]]*\] /, ""); print $3 }' <<< "${helper_info}" | sort -u)
    foreign_suites=$(grep -v -E "^${release}(-updates|-security)?$" <<< "${suites}")

    if [ "${codename}" != "${release}" ] || [ -z "${suites}" ] || [ -n "${foreign_suites}" ]
    then
      error "${policy}: helper ${helper} is debian '${codename}' with apt suites '${suites//[$'\r\n']/ }', expected ${release} only"
      RETURN_ERROR=$((RETURN_ERROR + 1))
    else
      success "${policy}: helper ${helper} is debian ${release} with apt suites ${suites//[$'\r\n']/ }"
    fi
    docker rmi -f "${helper}" > /dev/null 2>&1
  done
done

exit ${RETURN_ERROR}
