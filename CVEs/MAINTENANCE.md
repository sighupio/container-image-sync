# How to generate CVE reports for a distro version

This guide explains how to generate a new report (in MarkDown) for a version of the distribution.

## Requirements

* `trivy` command line installed
* `jq` command line installed
* `awk` command line installed

## Run using GitHub Actions

The [workflow](.github/workflows/cve-scan-and-patching.yml) is triggered at every change in the following files:
- .github/workflows/cve-scan-and-patching.yml
- CVEs/**

### How to add new SKD version

1) Run `furyctl create config --name sighup --version v1.X.Y --kind KFDDistribution --config v1.X.Y/furyctl.yaml`

> The command creates a new folder named with the version of SKD and a new `furyctl.yaml` file with cluster name `sighup`, the same distribution version, and kind `KFDDistribution` (everything can be disabled in the furyctl.yaml file, we only need to download the dependencies).  
2) Commit and push the new folder

### What the workflow does

The workflow performs the following tasks: 
- check the SKD versions defined in folders following the pattern `vX.Y.Z`
- for each SKD version found, execute the "scan pre patch" makefile target:
  - download all dependencies
  - build all dependencies manifests
  - generate the list of images present in the manifests
  - scan the images with trivy
  - create the `FURY-CVEs.md` CVEs report  
- execute the patch of all the images used by all SKD versions
- for each SKD version found, execute the "scan post patch" makefile target:
  - scan the patched images with trivy
  - create the `FURY-SECURED-CVEs.md` CVEs report
- publish the reports as artifact of [worflow run](https://github.com/sighupio/container-image-sync/actions/workflows/cve-scan-and-patching.yml)

## Run locally

### Scanning for CVEs

#### Scan a new single SKD Version

1) Create a new folder with the name of the version of SKD and create a new `furyctl.yaml` file with cluster name `sighup` and the same distribution version with kind KFDDistribution (everything can be disabled, we only need to download the dependencies): `furyctl create config --name sighup --version v1.X.Y --kind KFDDistribution --config v1.X.Y/furyctl.yaml`
2) Execute `make download-deps SKD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE` 
3) Execute `make kustomize-build-all SKD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE` 
4) Execute `make trivy-download-db`
5) Execute `make generate-image-list-from-manifests SKD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE`, this command will output an `SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/images.txt` file with all the images found in the build kustomize manifest. 
6) Execute `make scan-vulns SKD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE`, this script will output a `SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/CVEs.md` file in the current directory with a table with all the CRITICAL CVEs 
7) Check the `SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/CVEs.md`.

#### Scan all defined SKD versions

1) Execute `make trivy-download-db`
2) Execute `make scan-pre-patch`
3) Check the `FURY-CVEs.md` file in each version directory

### Scanning and patching CVEs

By default the patching phase will not push the images on the registry. To push images use `make patch DRY_RUN=0 [...]`

#### Patching a new single SKD Version

1) Create a new folder with the name of the version of SKD and create a new `furyctl.yaml` file with cluster name `sighup` and the same distribution version with kind KFDDistribution (everything can be disabled, we only need to download the dependencies): `furyctl create config --name sighup --version v1.X.Y --kind KFDDistribution --config v1.X.Y/furyctl.yaml`
2) Execute `make trivy-download-db`
3) Execute `make scan-pre-patch FURY_VERSIONS=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE` 
4) Execute `make patch PATCH_FILE_IMAGE_LIST_TO_PATCHING=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/images.txt`
5) Check the `SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/PATCHED.md`.

#### Scanning and patching all defined SKD versions

1) Execute `make trivy-download-db`
2) Execute `make scan-pre-patch`
2) Execute `make concat-multiple-kfd-images-list`
2) Execute `make patch`
3) Check the `PATCHED.md` file in each version directory

## Copacetic helper image

Copa uses a Debian helper image to download and inject updated packages into the target image filesystem. By default it pulls `ghcr.io/project-copacetic/copacetic/debian:stable-slim`.

`Dockerfile.copacetic-helper` and `copacetic-source-policy.json` override that default with a custom image hosted at `registry.sighup.io/utilities/copacetic/debian`. This was necessary for two reasons:

- when Debian 13 (Trixie) became stable, the `stable-slim` tag started pointing to Trixie repositories. The images we patch are still based on Debian 12 (Bookworm), so `apt-get download` failed with `Unable to locate package` for packages that no longer exist or have different names in Trixie.
- `debian:12-slim` alone is missing `debconf`, `perl` and `libterm-readline-perl-perl`. Without them, `dpkg` fails when installing packages with post-install configuration scripts (e.g. `libc6`, `tzdata`) with `No config file found at /usr/share/perl5/Debconf/Config.pm`.

### How to update the helper image

The helper image must be rebuilt when the patching pipeline fails with `E: Unable to locate package <package>`. This happens when the packages installed in the target images have been renamed or updated in Debian (e.g. the `t64` transition from `libssl3` tp `libssl3t64`) but the pinned helper image predates those changes.

Requirements:

* `docker` with `buildx` support
* push access to `registry.sighup.io/utilities/copacetic/`

1) Log in to the registry: `docker login registry.sighup.io`
2) Create a multi-arch builder if one does not exist yet: `docker buildx create --name multiarch --use --bootstrap`
3) Build and push the updated image:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --file CVEs/Dockerfile.copacetic-helper \
  --push \
  -t registry.sighup.io/utilities/copacetic/debian:latest \
  CVEs/
```

4) Get the new digest: `docker buildx imagetools inspect registry.sighup.io/utilities/copacetic/debian:latest --format '{{json .Manifest.Digest}}'`
5) Update both rules in `copacetic-source-policy.json` with the new digest:

```json
"identifier": "docker-image://registry.sighup.io/utilities/copacetic/debian@sha256:<new-digest>"
```

6) Commit and push
