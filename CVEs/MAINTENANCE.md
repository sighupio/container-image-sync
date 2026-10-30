# How to generate CVE reports for a distro version

This guide explains how to generate a new report (in MarkDown) for a version of the distribution.

## Requirements

* `trivy` command line installed
* `jq` command line installed
* `awk` command line installed
* `furyctl` command line installed
* `docker`, `copa` and `buildctl` command lines installed, to patch the images

## Run using GitHub Actions

The [workflow](../.github/workflows/cve-scan-and-patching.yml) is triggered every Sunday and at every change in the following files:
- .github/workflows/cve-scan-and-patching.yml
- CVEs/** (except CVEs/MAINTENANCE.md)

### How to add new SKD version

1) Run `furyctl create config --name sighup --version v1.X.Y --kind KFDDistribution --config v1.X.Y/furyctl.yaml`

> The command creates a new folder named with the version of SKD and a new `furyctl.yaml` file with cluster name `sighup`, the same distribution version, and kind `KFDDistribution` (everything can be disabled in the furyctl.yaml file, we only need to download the dependencies).  
2) Commit and push the new folder

> Some modules are downloaded by furyctl only for some cluster kinds (e.g. `aws` only for `EKSCluster`, `utilities` only for `OnPremises` and `Immutable`). To scan all of them, put one subfolder per kind inside the version folder, each with its own `furyctl.yaml` (e.g. `v1.36.0/ekscluster/furyctl.yaml` and `v1.36.0/onpremises/furyctl.yaml`): the dependencies of every kind are downloaded and built into a single `images.txt` and a single report for the version.

### What the workflow does

The workflow performs the following tasks: 
- check the SKD versions defined in folders following the pattern `vX.Y.Z`
- for each SKD version found, execute the "scan pre patch" makefile target:
  - download all dependencies
  - build all dependencies manifests
  - generate the list of images present in the manifests
  - scan the images with trivy
  - create the `FURY-CVEs.md` CVEs report  
- check the Copacetic helper images
- execute the patch of all the images used by all SKD versions
- for each SKD version found, execute the "scan post patch" makefile target:
  - scan the patched images with trivy
  - create the `FURY-SECURED-CVEs.md` CVEs report
- publish the reports as artifact of [worflow run](https://github.com/sighupio/container-image-sync/actions/workflows/cve-scan-and-patching.yml)

## Run locally

### Scanning for CVEs

#### Scan a new single SKD Version

1) Create a new folder with the name of the version of SKD and create a new `furyctl.yaml` file with cluster name `sighup` and the same distribution version with kind KFDDistribution (everything can be disabled, we only need to download the dependencies): `furyctl create config --name sighup --version v1.X.Y --kind KFDDistribution --config v1.X.Y/furyctl.yaml`
2) Execute `make download-deps KFD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE` 
3) Execute `make kustomize-build-all KFD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE` 
4) Execute `make trivy-download-db`
5) Execute `make generate-image-list-from-manifests KFD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE`, this command will output an `SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/images.txt` file with all the images found in the build kustomize manifest. 
6) Execute `make scan-vulns KFD_VERSION=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE`, this script will output a `SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/CVEs.md` file with a table with all the CRITICAL CVEs 
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
3) Execute `make scan-pre-patch KFD_VERSIONS=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE` 
4) Execute `make patch PATCH_FILE_IMAGE_LIST_TO_PATCHING=SOME_VALID_SKD_VERSION_WITH_A_FURYCTLYAML_INSIDE/images.txt`
5) Check the `PATCHED.md` file

#### Scanning and patching all defined SKD versions

1) Execute `make trivy-download-db`
2) Execute `make scan-pre-patch`
2) Execute `make concat-multiple-kfd-images-list`
2) Execute `make patch`
3) Check the `PATCHED.md` file

## Copacetic helper image

To patch a Debian image without apt (e.g. distroless), Copa downloads the updated packages with `apt` in a separate Debian container, the helper image, and installs them into the image to patch. The BuildKit source policies `copacetic-source-policy.<release>.json` replace the default helper with `registry.sighup.io/utilities/copacetic/debian`, built from `Dockerfile.copacetic-helper`:

- `copacetic-source-policy.bookworm.json` for Debian 12 (tag `12-debconf`)
- `copacetic-source-policy.trixie.json` for Debian 13 (tag `13-debconf`)

`copacetic_os.sh` chooses the policy from the Debian version detected by Trivy and, after the patch, checks that the updated packages belong to the same release; otherwise the original image is copied unpatched. The `check_copacetic_helpers` job checks the helpers before patching.

### How to add the helper of a new Debian release

Requirements:

* `docker` with `buildx` support
* push access to `registry.sighup.io/utilities/copacetic/`

1) Log in to the registry: `docker login registry.sighup.io`
2) Create a multi-arch builder if one does not exist yet: `docker buildx create --name multiarch --use --bootstrap`
3) Build and push the helper of the new release:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --file CVEs/Dockerfile.copacetic-helper \
  --build-arg DEBIAN_RELEASE=forky \
  --push \
  -t registry.sighup.io/utilities/copacetic/debian:14-debconf \
  CVEs/
```

4) Get the new digest: `docker buildx imagetools inspect registry.sighup.io/utilities/copacetic/debian:14-debconf --format '{{json .Manifest.Digest}}'`
5) Add `CVEs/copacetic-source-policy.forky.json`, copied from an existing policy with the `14-slim` selectors and the new digest, and the release in `source_policy_for` (`CVEs/copacetic_os.sh`)
6) Run `make check-copacetic-helpers` in `CVEs/`
7) Commit and push
