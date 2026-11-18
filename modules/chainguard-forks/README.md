# Chainguard Forks Catalog

This document tracks the Chainguard-maintained forks of upstream projects
that we have adopted in `container-image-sync`. For each fork we record:
upstream provenance, the reason we adopted the fork, the resulting registry
mapping, the build cascade (when applicable), and the bump procedure.

For the concrete versions currently in use, look at the corresponding
[`images.yml`](images.yml) — this document deliberately does not pin
versions, so it does not go stale every time a tag is bumped.

When adopting a new fork, append a section here using the same shape.

---

## ingress-nginx

- **Upstream**: `kubernetes/ingress-nginx` (archived March 2026)
- **Chainguard fork**: <https://github.com/chainguard-forks/ingress-nginx>
- **Rationale**: the upstream project is archived; the Chainguard fork
  backports CVE fixes on two distinct layers — the `nginx` base image (with
  the ingress-nginx modules compiled in: Lua, OpenTelemetry, ModSecurity,
  HTTP/3) and the Go controller. To benefit from those patches we have to
  build BOTH layers from the fork.
- **Sync config**: [`images.yml`](images.yml)

### Images and registry mapping

| Image      | Source dir in fork    | Push destination (path)                            |
|------------|-----------------------|----------------------------------------------------|
| nginx base | `images/nginx/rootfs` | `registry.sighup.io/fury/ingress-nginx/nginx`      |
| controller | `rootfs`              | `registry.sighup.io/fury/ingress-nginx/controller` |

The image tag we publish always carries a `-chainguard` suffix so that it
is unambiguous against the legacy upstream mirror that lives at the same
controller path (`registry.sighup.io/fury/ingress-nginx/controller`).

Both entries are driven from the same `git_source.ref` so the build is
reproducible from a single tag of the fork. At the controller release tag
the fork records the matching nginx version in `images/nginx/TAG`, so one
ref is enough to drive both builds.

### Build cascade

The controller image's `BASE_IMAGE` build-arg points to the destination tag
of the just-pushed nginx base image. For the cascade to resolve correctly
the nginx base entry MUST appear before the controller entry in
[`images.yml`](images.yml). The sync script processes entries in order,
so the order in the file determines the build order.

The controller entry additionally requires a pre-build step: the fork's
`rootfs/Dockerfile` is not self-contained and expects pre-cross-compiled Go
binaries at `rootfs/bin/<arch>/{nginx-ingress-controller,dbg,wait-shutdown}`.
Those are produced by the fork's own `make build ARCH=<arch>` target (which
wraps `go build` inside a `golang:VERSION-alpine3.23` container via
`build/run-in-docker.sh`). This is configured via `build.pre_build_commands`
on the controller entry, with one `make build` invocation per target
architecture. Pass `TAG=<controller-version>` explicitly to embed the
correct release string in the Go binary (the fork's root `TAG` file is
inconsistent with its git tags).

### Bump procedure

1. Look up the latest `controller-v*` tag in the fork and read
   `images/nginx/TAG` at that tag to get the matching nginx version.
2. Append a new nginx/controller pair to [`images.yml`](images.yml):
   - Both new entries: `build.git_source.ref` → the new fork tag.
   - nginx entry: `tag` value → `<NEW_NGINX_VERSION>-chainguard`.
   - controller entry:
     - `build.pre_build_commands` → both lines updated to
       `make build ARCH=<arch> TAG=<NEW_CONTROLLER_VERSION>`.
     - `build.args[name=BASE_IMAGE].value` → must match the new nginx
       destination tag exactly (this is the cross-reference that the
       cascade depends on).
     - `build.args[name=VERSION].value` → new controller version.
     - `tag` value → `<NEW_CONTROLLER_VERSION>-chainguard`.
3. Open a PR. CI will build and push both images in cascade.
4. Once the new images are published and validated, open a follow-up PR on
   `module-ingress` to bump the `newTag` in
   `katalog/nginx/bases/controller/kustomization.yaml` to the new
   `-chainguard` tag.

---

## minio

- **Upstream**: `minio/minio` (archived; images removed from Docker Hub and Quay)
- **Chainguard fork**: <https://github.com/chainguard-forks/minio>
- **Rationale**: the upstream project is archived and no longer publishes
  images; the fork backports CVE fixes and publishes a `RELEASE.*` tag for
  each update.
- **Sync config**: [`images.yml`](images.yml)

| Image | Source in fork            | Push destination (path)        |
|-------|---------------------------|--------------------------------|
| minio | `Dockerfile.dev` (root)   | `registry.sighup.io/fury/minio` |

The tag we publish is the fork tag with a `-chainguard` suffix.
`Dockerfile.dev` is self-contained (Go build stage + `wolfi-base` runtime with
`docker-entrypoint.sh`, `bash` and `mc`), so no pre-build commands are needed.

### Notes

The runtime base is now `wolfi-base` instead of `minio/minio`. The entrypoint,
`sh`, `bash` and `mc` are the same, with these differences:

- `curl` is not available: use `busybox`, that is now included.
- `MC_CONFIG_DIR` is not set: when the container runs as a non-root user
  without a writable home, `mc` cannot save its config. Pass
  `--config-dir /tmp/.mc` or set `MC_CONFIG_DIR=/tmp/.mc`.
- The `MINIO_ROOT_USER_FILE`, `MINIO_ROOT_PASSWORD_FILE` and
  `MINIO_CONFIG_ENV_FILE` variables are not set, so the credentials are not
  read from files under `/run/secrets`: pass `MINIO_ROOT_USER` /
  `MINIO_ROOT_PASSWORD` as environment variables.
- `EXPOSE 9000` and `WORKDIR /` are not set: declare the ports in the Pod spec
  and use absolute paths for data, certificates and keys. The working
  directory defaults to `/`.

### Bump procedure

1. Pick the latest `RELEASE.*` tag of the fork.
2. Append a new entry to [`images.yml`](images.yml) with `build.git_source.ref`
   set to the new tag and `tag` set to `<NEW_TAG>-chainguard`.
3. Open a PR. CI will build and push the image.


<!-- Append new forks below this line, using the same section template. -->