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
└── values.yaml          # plain Helm values -> baked into the ConfigMap
```

Multi-release apps (istio) use one shared source and a values file per release:

```text
apps/istio/
├── kustomization.yaml
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

## Apps (40)

| App | Chart source |
|-----|--------------|
| aws-efs-csi-driver | kubernetes-sigs.github.io/aws-efs-csi-driver |
| aws-load-balancer-controller | aws.github.io/eks-charts |
| cert-manager | charts.jetstack.io |
| external-secrets | charts.external-secrets.io |
| external-dns | kubernetes-sigs/external-dns |
| metrics-server | kubernetes-sigs/metrics-server |
| reloader | stakater |
| coredns | ghcr/coredns (OCI) |
| spegel | ghcr/spegel-org (OCI) |
| csi-driver-nfs | kubernetes-csi |
| cilium | quay.io/cilium (OCI) |
| keda | kedacore |
| kyverno | kyverno |
| node-feature-discovery | kubernetes-sigs |
| cloudnative-pg | cloudnative-pg |
| dragonfly-operator | ghcr/dragonflydb (OCI) |
| nats | nats-io |
| vault | helm.releases.hashicorp.com |
| openebs | openebs.github.io |
| argocd | argoproj |
| ingress-nginx | kubernetes/ingress-nginx |
| traefik | traefik.github.io |
| k8s-gateway | ori-edge/k8s_gateway |
| istio | istio-release.storage.googleapis.com (4 releases) |
| vpa | charts.fairwinds.com |
| goldilocks | charts.fairwinds.com |
| kube-prometheus-stack | ghcr/prometheus-community (OCI) |
| grafana-operator | ghcr/grafana (OCI) |
| loki | ghcr/grafana-community (OCI) |
| tempo | ghcr/grafana-community (OCI) |
| alloy | grafana.github.io |
| fluent-bit | fluent.github.io |
| blackbox-exporter | ghcr/prometheus-community (OCI) |
| gatus | twin.github.io |
| victoria-metrics | ghcr/victoriametrics (OCI) |
| victoria-logs | ghcr/victoriametrics (OCI) |
| gitlab-agent | charts.gitlab.io |
| gitlab-runner | charts.gitlab.io |
| kong-gateway-operator | charts.konghq.com |
| pangolin-gateway-controller | github.com/dxas90/pangolin-gateway-controller (GitRepository) |

## Namespace ownership

The catalog declares no namespaces: no `metadata.namespace`, generator namespace,
or Namespace resources. Sources, HelmReleases and generated ConfigMaps stay together
in the namespace selected by the consumer. `sourceRef`, `valuesFrom` and `dependsOn`
references remain local to that namespace.

Create the destination namespace in your provisioning/platform layer first. Then
set `spec.targetNamespace` on the consuming Flux Kustomization, or use a local
Kustomize overlay:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: my-platform
resources:
- ../../apps/cert-manager
```

Flux `spec.targetNamespace` does not itself create the namespace. With no explicit
namespace selection, Kubernetes defaults apply; this is not a deployment choice
made by the catalog.

Alloy's Tempo endpoint and Fluent Bit's Loki endpoint use same-namespace service
DNS. If these backends live elsewhere, override those endpoints in the consumer.
Chart defaults can still contain namespace assumptions: particularly Istio control
plane discovery/CNI integration and system addons. Set the chart-specific namespace
values when relocating them; removing manifest namespaces does not make every
upstream chart portable without configuration. Cluster-scoped CRDs/RBAC also remain
cluster-scoped, so arbitrary multiple installations are not implied.

## Validate

```bash
# single app
kustomize build apps/<name>

# all apps
for a in apps/*/; do kustomize build "$a" >/dev/null && echo "OK $a"; done
```

The Helm renderer uses `catalog-test` when a release has no explicit namespace.
Set `RENDER_NAMESPACE` to test another namespace. Rendering is an offline check,
not proof of live reconciliation or chart-specific relocation support.

## Bumping chart versions

Versions are pinned in `source.yaml` (`tag:` for OCI repos) or `release.yaml`
(`version:` for Helm repos). Bump them in place — or let Renovate track
`version:`/`tag:` fields — then re-run the validation above.
