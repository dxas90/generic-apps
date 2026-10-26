#!/usr/bin/env python3
"""Render every HelmRelease in apps/ with its pinned chart version and values.

Reads the manifests directly (source.yaml + release*.yaml), so new apps and
version bumps are picked up automatically. Uses an isolated Helm home so a
broken local repo index cannot affect the result.

Usage: uv run --with pyyaml python scripts/render-helm.py [app ...]
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
APPS = ROOT / "apps"
KUBE_VERSION = os.environ.get("KUBE_VERSION", "1.33.0")


def load(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]


def releases(app_dir):
    sources = {}
    for f in app_dir.glob("*.yaml"):
        for d in load(f):
            if d.get("kind") in ("HelmRepository", "OCIRepository", "GitRepository"):
                s = d["spec"]
                sources[d["metadata"]["name"]] = (d["kind"], s["url"], (s.get("ref") or {}).get("tag"))
    for f in sorted(app_dir.glob("release*.yaml")):
        for d in load(f):
            if d.get("kind") != "HelmRelease":
                continue
            spec = d["spec"]
            chart = (spec.get("chart") or {}).get("spec") or {}
            src = (chart.get("sourceRef") or {}).get("name") or spec["chartRef"]["name"]
            kind, url, tag = sources.get(src, (None, None, None))
            if kind in (None, "GitRepository"):
                # helm template cannot pull from git URLs; skip render
                continue
            values = app_dir / f.name.replace("release", "values")
            if not values.exists():
                values = app_dir / "values.yaml"
            yield {
                "name": d["metadata"]["name"],
                "ns": d["metadata"].get("namespace", os.environ.get("RENDER_NAMESPACE", "catalog-test")),
                "kind": kind,
                "url": url,
                "chart": chart.get("chart"),
                "version": chart.get("version") or tag,
                "values": values,
            }


def render(r, cwd):
    cmd = ["helm", "template", r["name"]]
    if r["kind"] == "OCIRepository":
        cmd.append(r["url"])
    else:
        cmd += [r["chart"], "--repo", r["url"]]
    cmd += ["--version", r["version"], "-n", r["ns"], "-f", str(r["values"]),
            "--kube-version", KUBE_VERSION]
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def main():
    selected = set(sys.argv[1:])
    fail = 0
    with tempfile.TemporaryDirectory() as home:
        # Isolated Helm state; cwd is also the empty temp dir so chart names
        # are never resolved as local directories.
        for var in ("HELM_CACHE_HOME", "HELM_CONFIG_HOME", "HELM_DATA_HOME"):
            os.environ[var] = os.path.join(home, var.lower())
        for app_dir in sorted(p for p in APPS.iterdir() if p.is_dir()):
            if selected and app_dir.name not in selected:
                continue
            for r in releases(app_dir):
                res = render(r, home)
                label = f"{app_dir.name}/{r['name']}@{r['version']}"
                if res.returncode == 0:
                    print(f"OK   {label} ({res.stdout.count(chr(10) + 'kind:')} objs)")
                else:
                    fail = 1
                    print(f"FAIL {label}\n  " + "\n  ".join(res.stderr.strip().splitlines()[-3:]))
    sys.exit(fail)


if __name__ == "__main__":
    main()
