<!-- markdownlint-disable MD033 -->
<h1 align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/sighupio/distribution/refs/heads/main/docs/assets/white-logo.png">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/sighupio/distribution/refs/heads/main/docs/assets/black-logo.png">
  <img alt="Shows a black logo in light color mode and a white one in dark color mode." src="https://raw.githubusercontent.com/sighupio/distribution/refs/heads/main/docs/assets/white-logo.png">
</picture><br/>
  Container Image Sync
</h1>
<!-- markdownlint-enable MD033 -->

# Table of contents
- [Introduction](#introduction)
- [How it works](#how-it-works)
- [External git sources](#external-git-sources)
- [Automated sync execution](#automated-sync-execution)
- [Vulnerability detection and patching](#vulns-detect-and-patch)

## <a name="introduction">Introduction</a>

This is a simple mechanism that pulls and pushes or builds container images based on a configuration file (`yaml`).

The main goal for this repository is to have a central location used to sync on our public SIGHUP registry all the
upstream images used by all the SD modules.

The goal of this repository is twofold: build custom images and sync upstream ones used by all the SD modules on
our public SIGHUP registry.

Features:

- Configurable via YAML files
- Build custom images
- Skips images if the layers between src and dest are the same using `skopeo`
- Everything is executed with bash script `scripts/sync.sh` that by default will sync all image architectures
- Execute the vulnerability detection and patching of synced images with amd64 and arm64 architectures

## <a name="how-it-works">How it works</a>

Inside the folder `modules/` there is a subfolder for each SD module with an `images.yml` file.

Each `images.yml` file has to have a root attribute: `images` and its value is an array of objects:

```yaml
  - name: # Simple description of the image
    source: # Source image. Where to pull the image
    tag: # Tags to sync
      - "xxx"
    destination:
      - # Destination registry
```
or (when building):
```yaml
  - name: # Simple description of the image
    source: # Local name used by the newly built image
    build: # Build parameters
      context: # Path where the Dockerfile is stored (relative to images.yml file)
      args: # Build arguments
        - name: # Build argument name
          value: # Build argument value
    tag: # New image tag
      - "xxx"
    destination:
      - # Destination registry
```

Example `images.yml`:

```yaml
  - name: Alpine
    source: docker.io/library/alpine
    tag:
      - "3"
      - "3.12"
      - "3.13"
      - "3.14"
    destinations:
      - registry.sighup.io/fury/alpine

  - name: Grafana
    source: grafana
    build:
      context: custom/grafana
      args:
        - name: GF_INSTALL_PLUGINS
          value: grafana-piechart-panel
    tag:
      - "8.5.5"
    destinations:
      - registry.sighup.io/fury/grafana/grafana
```

## <a name="external-git-sources">External git sources</a>

Custom builds can take their build context from an external git repository
instead of a path local to the module. This is useful when we want to build
an image from a maintained fork (for example a security-patched fork of an
upstream project) without vendoring the source code into this repository.

Set `build.git_source` on the image entry:

```yaml
  - name: Example image from external repo
    source: example-local-name
    multi-arch: true
    build:
      git_source:
        repo: https://github.com/some-org/some-repo.git
        ref: v1.2.3                # tag or branch (not a raw commit SHA)
      context: path/inside/the/clone
      args:
        - name: VERSION
          value: "v1.2.3"
    tag:
      - "v1.2.3-custom"
    destinations:
      - registry.sighup.io/fury/example/image
```

How it works at sync time:

- The script clones the repo shallow at the given `ref` into a temporary
  directory and uses `<tempdir>/<context>` as the docker build context.
- The temporary clone is removed when the entry finishes, regardless of
  success or failure.
- `build.context` is required when `git_source` is set; if it is missing
  the entry fails with an explicit error.
- When `git_source` is present, the local path
  `dirname(images.yml)/<context>` is ignored.

### Pre-build commands

Some forks ship Dockerfiles that are NOT self-contained — they require code
generation, Go cross-compilation, or other prep before `docker build` can run
(for example the Chainguard `ingress-nginx` fork's `rootfs/Dockerfile` does
`COPY bin/${TARGETARCH}/...` expecting Go binaries that the project's own
`make build ARCH=<arch>` target produces).

To handle this, add `build.pre_build_commands`: a list of shell command strings
executed sequentially with `bash -c`, in `dirname(<context>)` (the parent of
the docker build context — i.e. the clone root for `git_source` builds), AFTER
the clone and BEFORE the `docker buildx build`. If any command fails the entry
aborts.

```yaml
  - name: Example with pre-build
    source: example-local-name
    multi-arch: true
    build:
      git_source:
        repo: https://github.com/some-org/some-repo.git
        ref: v1.2.3
      pre_build_commands:
        - "make build ARCH=amd64 TAG=v1.2.3"
        - "make build ARCH=arm64 TAG=v1.2.3"
      context: rootfs
      args:
        - name: VERSION
          value: "v1.2.3"
    tag:
      - "v1.2.3-custom"
    destinations:
      - registry.sighup.io/fury/example/image
```

For the current catalog of Chainguard-maintained forks adopted with this
mechanism (image mappings to the SIGHUP registry and bump procedures),
see [`modules/chainguard-forks/README.md`](modules/chainguard-forks/README.md).

## <a name="automated-sync-execution">Automated sync execution</a>

This automation runs once a day: `"0 2 * * *"` and every time someone pushes to the `main` branch.

## <a name="vulns-detect-and-patch">Vulnerability detection and patching</a>

The reports of vulnerability scanning and patching are available in the dedicate [worflow run](https://github.com/sighupio/container-image-sync/actions/workflows/cve-scan-and-patching.yml) page.

On each `workflow run`, navigate to the **Artefacts** section where you can find:

- the `cve-reports-vX.Y.Z` artefact (zip file) that includes the pre patching and post patching vulnerabilities reports for SD version `X.Y.Z`.
- the `cve-patch-reports-by-image` artefact (zip file) that includes the patching report by image for all the images used in all the supported SD versions.
