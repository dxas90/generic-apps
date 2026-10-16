# generic-apps

A clean, reusable catalog of FluxCD application definitions you can drop into
any cluster. Pick the apps you want and point a Flux Kustomization at
`apps/<name>` — no environment overlays live here.

This directory contains **only the apps** — no cluster bootstrap, no
FluxInstance, no environment-specific config. Wire them into your own
`clusters/`/`platform/` layer (one `kustomize.toolkit.fluxcd.io/Kustomization`
per app, with `dependsOn` where ordering matters).

> Note: gateway-api CRDs, prometheus-operator CRDs and other "baseline" CRDs
> belong in the provisioning/bootstrap step (e.g. via a seed kustomization like
> `references/seed/bootstrap/kustomization.yaml`), not here.

## Structure

Every single-release app is flat:

```text
apps/<name>/
├── kustomization.yaml   # resources + configMapGenerator for <name>-values
├── source.yaml          # HelmRepository or OCIRepository
├── release.yaml         # HelmRelease (valuesFrom the generated ConfigMap)
├── values.yaml          # plain Helm values -> baked into the ConfigMap
└── namespace.yaml       # only when the app owns a dedicated namespace
```

Multi-release apps (istio) use one shared source and a values file per release:

```text
apps/istio/
├── kustomization.yaml
├── namespace.yaml
├── source.yaml             # one HelmRepository shared by all releases
├── release-base.yaml       # istio-base
├── release-istiod.yaml     # istiod
├── release-cni.yaml        # istio-cni
├── release-ztunnel.yaml    # ztunnel
├── values-base.yaml
├── values-istiod.yaml
├── values-cni.yaml
└── values-ztunnel.yaml
```

## The values pattern

Values live as a plain file and are turned into a stable ConfigMap by
`kustomization.yaml`:

```yaml
configMapGenerator:
- name: <release>-values
  files:
  - values.yaml=values-<release>.yaml   # or just values.yaml for single-release
generatorOptions:
  disableNameSuffixHash: true
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

The `HelmRelease` consumes it via:

```yaml
valuesFrom:
- kind: ConfigMap
  name: <release>-values
  valuesKey: values.yaml
```

To override per-environment, regenerate the **same** ConfigMap name with
`behavior: replace` from an overlay — no second `-overrides` ConfigMap needed.

## Apps (34)

| App | Namespace | Chart source |
|-----|-----------|--------------|
| cert-manager | cert-manager | charts.jetstack.io |
| external-secrets | external-secrets | charts.external-secrets.io |
| external-dns | external-dns | kubernetes-sigs/external-dns |
| metrics-server | kube-system | kubernetes-sigs/metrics-server |
| reloader | kube-system | stakater |
| coredns | kube-system | ghcr/coredns (OCI) |
| spegel | kube-system | ghcr/spegel-org (OCI) |
| csi-driver-nfs | kube-system | kubernetes-csi |
| cilium | kube-system | quay.io/cilium (OCI) |
| keda | keda | kedacore |
| kyverno | kyverno | kyverno |
| node-feature-discovery | node-feature-discovery | kubernetes-sigs |
| cloudnative-pg | cnpg-system | cloudnative-pg |
| dragonfly-operator | dragonfly-system | ghcr/dragonflydb (OCI) |
| nats | nats | nats-io |
| vault | vault | helm.releases.hashicorp.com |
| openebs | openebs | openebs.github.io |
| argocd | argocd | argoproj |
| ingress-nginx | ingress-nginx | kubernetes/ingress-nginx |
| traefik | traefik | traefik.github.io |
| k8s-gateway | k8s-gateway | ori-edge/k8s_gateway |
| istio | istio-system | istio-release.storage.googleapis.com (4 releases) |
| vpa | vpa | charts.fairwinds.com |
| goldilocks | goldilocks | charts.fairwinds.com |
| kube-prometheus-stack | observability | ghcr/prometheus-community (OCI) |
| grafana-operator | observability | ghcr/grafana (OCI) |
| loki | observability | ghcr/grafana-community (OCI) |
| tempo | observability | ghcr/grafana-community (OCI) |
| alloy | observability | grafana.github.io |
| fluent-bit | observability | fluent.github.io |
| blackbox-exporter | observability | ghcr/prometheus-community (OCI) |
| gatus | observability | twin.github.io |
| victoria-metrics | observability | ghcr/victoriametrics (OCI) |
| victoria-logs | observability | ghcr/victoriametrics (OCI) |

Apps that own their namespace ship a `namespace.yaml`; the rest expect theirs
(`observability`, `kube-system`, `argocd`, `cert-manager`, …) to be created
by your platform layer.

## Validate

```bash
# single app
kustomize build apps/<name>

# all apps
for a in apps/*/; do kustomize build "$a" >/dev/null && echo "OK $a"; done
```

All 34 apps build with kustomize v5 and every chart renders cleanly with
`helm template` against its pinned version.

## Bumping chart versions

Versions are pinned in `source.yaml` (`tag:` for OCI repos) or `release.yaml`
(`version:` for Helm repos). Bump them in place — or let Renovate track
`version:`/`tag:` fields — then re-run the validation above.
