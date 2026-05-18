# Chainguard Forks Catalog

This document tracks the Chainguard-maintained forks of upstream projects
that we have adopted in `container-image-sync`. For each fork we record:
upstream provenance, the reason we adopted the fork, the resulting registry
mapping, the build cascade (when applicable), and the bump procedure.

For the concrete versions currently in use, look at the corresponding
`images.yml` — this document deliberately does not pin versions, so it
does not go stale every time a tag is bumped.

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
- **Sync config**: [`modules/ingress/images.yml`](../modules/ingress/images.yml)

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
`modules/ingress/images.yml`. The sync script processes entries in order,
so the order in the file determines the build order.

### Bump procedure

1. Look up the latest `controller-v*` tag in the fork and read
   `images/nginx/TAG` at that tag to get the matching nginx version.
2. Update [`modules/ingress/images.yml`](../modules/ingress/images.yml):
   - Both entries: `build.git_source.ref` → the new fork tag.
   - nginx entry: `tag` value → `<NEW_NGINX_VERSION>-chainguard`.
   - controller entry:
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

<!-- Append new forks below this line, using the same section template. -->
