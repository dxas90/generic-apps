---
name: add-app
description: Add, remove, or manage FluxCD apps in this generic-apps catalog. Guides agents through creating correct file sets, picking the right source type, and running validation.
---

# add-app — Manage the generic-apps catalog

Use this skill whenever the user asks to add, remove, or update an app entry in this
FluxCD app catalog at `apps/`.

---

## Repo structure recap

Every single-release app is four files:

```
apps/<name>/
├── kustomization.yaml   # resources + configMapGenerator
├── source.yaml          # HelmRepository | OCIRepository | GitRepository
├── release.yaml         # HelmRelease referencing the ConfigMap
└── values.yaml          # plain Helm values
```

Multi-release apps (like `istio`) share one `source.yaml` and have one
`release-<component>.yaml` + `values-<component>.yaml` per component.

---

## Adding a new app

### Step 1 — Identify the source type

| Chart is served via | source kind |
|---------------------|-------------|
| `https://` Helm repo index | `HelmRepository` |
| `oci://` OCI registry | `OCIRepository` |
| Git repo containing a chart dir | `GitRepository` |

### Step 2 — Create `apps/<name>/source.yaml`

**HelmRepository** (most common — e.g. traefik, cert-manager, vault):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <name>
spec:
  interval: 1h
  url: https://<helm-repo-url>
```

**OCIRepository** (e.g. loki, kube-prometheus-stack, cilium):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: <name>
spec:
  interval: 1h
  url: oci://<registry>/<path>/<chart>
  ref:
    tag: "<version>"
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

**GitRepository** (rare — e.g. pangolin-gateway-controller):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: <name>
spec:
  interval: 1h
  url: https://github.com/<org>/<repo>
  ref:
    tag: v<version>
```

### Step 3 — Create `apps/<name>/release.yaml`

**For HelmRepository or GitRepository source:**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <name>
spec:
  interval: 15m
  timeout: 10m
  releaseName: <name>
  maxHistory: 3
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    cleanupOnFail: true
    remediation:
      retries: 3
  driftDetection:
    mode: enabled
  valuesFrom:
  - kind: ConfigMap
    name: <name>-values
    valuesKey: values.yaml
  chart:
    spec:
      chart: <chart-name>
      version: <version>
      sourceRef:
        kind: HelmRepository   # or GitRepository
        name: <name>
```

> For GitRepository, `chart.spec.chart` is the path to the chart dir within the
> repo (e.g. `k8s/chart`). There is no `version:` field in that case.

**For OCIRepository source** — use `chartRef` instead of `chart.spec`:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <name>
spec:
  interval: 15m
  timeout: 10m
  releaseName: <name>
  maxHistory: 3
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    cleanupOnFail: true
    remediation:
      retries: 3
  driftDetection:
    mode: enabled
  valuesFrom:
  - kind: ConfigMap
    name: <name>-values
    valuesKey: values.yaml
  chartRef:
    kind: OCIRepository
    name: <name>
```

### Step 4 — Create `apps/<name>/values.yaml`

Start with an empty file or minimal overrides. If you don't have specific values,
a comment-only file is fine:

```yaml
# Default values — override in your consumer kustomization
```

### Step 5 — Create `apps/<name>/kustomization.yaml`

**Single-release app:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- source.yaml
- release.yaml
configMapGenerator:
- name: <name>-values
  files:
  - values.yaml
generatorOptions:
  disableNameSuffixHash: true
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

**Multi-release app** (when a single chart repo ships multiple independently-deployed
components, like Istio):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- source.yaml
- release-<component1>.yaml
- release-<component2>.yaml
configMapGenerator:
- name: <name>-<component1>-values
  files:
  - values.yaml=values-<component1>.yaml
- name: <name>-<component2>-values
  files:
  - values.yaml=values-<component2>.yaml
generatorOptions:
  disableNameSuffixHash: true
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

### Step 6 — Validate

Run both checks. If either fails, fix before proceeding.

```bash
# kustomize build
kustomize build apps/<name>

# helm template render (requires helm in PATH)
python scripts/render-helm.py <name>
```

Or validate everything at once with mise:
```bash
mise run validate
mise run validate/helm
```

### Step 7 — Update the README

1. Increment the app count in `## Apps (N)`.
2. Add a row to the table in alphabetical order:

```markdown
| <name> | <chart-source-url-or-registry> |
```

---

## Removing an app

1. Delete `apps/<name>/` entirely.
2. Update `README.md`: decrement the count and remove the table row.
3. Run `mise run validate` to confirm nothing is broken.

---

## Updating a chart version

**HelmRepository app** — edit `apps/<name>/release.yaml`, bump `spec.chart.spec.version`.

**OCIRepository app** — edit `apps/<name>/source.yaml`, bump `spec.ref.tag`.

**GitRepository app** — edit `apps/<name>/source.yaml`, bump `spec.ref.tag`.

Then validate:
```bash
python scripts/render-helm.py <name>
```

---

## Key constraints (do not violate)

- **No namespaces declared** — the catalog is namespace-agnostic. Never add
  `metadata.namespace`, `namespace:` in generators, or `Namespace` resources.
- **ConfigMap name must be stable** — `disableNameSuffixHash: true` is required so
  the `valuesFrom` reference in HelmRelease resolves correctly.
- **`reconcile.fluxcd.io/watch: Enabled`** label on every generated ConfigMap so
  Flux triggers reconciliation on value changes.
- **No environment overlays here** — per-environment config lives in the consumer's
  own kustomization layer, not in this catalog.
