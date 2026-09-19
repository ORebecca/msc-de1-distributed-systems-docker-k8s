# MSc DE1 — Distributed Systems: Docker & Local Kubernetes Project

Containerize, secure, publish and orchestrate the [UBC Flask Sample App](https://github.com/ubc/flask-sample-app)
— a small Flask REST API — using Docker, Docker Hub and a local multi-node
Kubernetes cluster (`kind`).

## 1. Objective and architecture overview

The goal of this project is **not** to redesign the application, but to build a
clean, secure and reproducible containerization + orchestration workflow around
it:

```
Flask app (unmodified logic)
     │  Dockerfile (non-root, slim/alpine base, healthcheck)
     ▼
Docker image ── docker compose (local dev) 
     │
     ▼
Docker Hub  (rebecca16ouatt/msc-de1-flask-app)
     │
     ▼
kind cluster (1 control-plane + 2 workers)
     │
     ▼
Kubernetes: Namespace, ConfigMap, Deployment (2 replicas, probes,
resource limits, hardened securityContext), Service, NetworkPolicy
```

## 2. Original starter application

- Source: <https://github.com/ubc/flask-sample-app>
- A small Flask REST API for managing an in-memory list of items, with an
  existing unittest suite.
- The only behavioral change made to the app: `run.py` now binds to
  `0.0.0.0` (configurable via the `PORT` env var) instead of Flask's default
  `127.0.0.1`, which is required for the app to be reachable from outside a
  container. Local, non-container usage is unaffected.
- A second small change (for the rolling-update/rollback demonstration in
  §9 of the assignment) updates the `/` route's text to include a version
  marker; the corresponding unit test was updated to match.

## 3. Prerequisites

- Python 3.12+ (for running the app locally without Docker)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [kind](https://kind.sigs.k8s.io/) (`winget install Kubernetes.kind` on Windows)
- `kubectl`
- [Trivy](https://aquasecurity.github.io/trivy/) and [Syft](https://github.com/anchore/syft) (only needed to re-run the security scans)

## 4. Run the original application locally (no Docker)

```bash
python -m venv venv
source venv/Scripts/activate   # Windows Git Bash; use venv/bin/activate on Linux/macOS
pip install -r requirements.txt
python run.py
# App available at http://localhost:5000

# In another terminal:
python -m unittest discover tests
```

Evidence of this baseline run is saved under `evidence/baseline/`.

## 5. Build and run the Docker image

```bash
docker build -t rebecca16ouatt/msc-de1-flask-app:1.0.0 .
docker run -d --name msc-de1-flask-app -p 5000:5000 rebecca16ouatt/msc-de1-flask-app:1.0.0

curl http://localhost:5000/
curl http://localhost:5000/items
docker logs msc-de1-flask-app
docker exec msc-de1-flask-app id     # confirms non-root (uid=100)

docker stop msc-de1-flask-app && docker rm msc-de1-flask-app
```

### Dockerfile design choices

- **Base image**: `python:3.12-alpine` — chosen over the Debian `slim`
  variant after a Trivy scan showed 150 OS-level vulnerabilities (44 HIGH) on
  Debian vs. 0 on Alpine for the same app. See `security/vulnerability-scan.txt`.
- Dependency file (`requirements.txt`) is copied and installed before the
  application source, so the dependency layer is cached across rebuilds.
- `pip`, `setuptools` and `wheel` are uninstalled after the dependency
  install — they are build-time only tools, not used at runtime, and were
  themselves flagged by the scanner.
- The app runs as a dedicated non-root user (`appuser`, uid 100, gid 101).
- Only port 5000 is exposed.
- `CMD ["python", "run.py"]` uses exec form so the process receives signals
  (e.g. `SIGTERM`) directly.
- A Docker `HEALTHCHECK` polls `GET /`.
- Final image size: ~78MB (down from ~198MB on the Debian-based build).

## 6. Run with Docker Compose

```bash
docker compose up -d
curl http://localhost:5000/
docker compose logs
docker compose down
```

`compose.yaml` hardens the container further for local testing:
`read_only: true` root filesystem (with a `tmpfs` mount for `/tmp`),
`cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, and no
privileged mode / Docker socket mount / host networking.

## 7. Docker Hub

Public repository: **<https://hub.docker.com/r/rebecca16ouatt/msc-de1-flask-app>**

Published tags:
- `1.0.0` — the version deployed to Kubernetes (see `k8s/deployment.yaml`)
- `latest` — same content as `1.0.0`
- `1.1.0` — used only for the rolling-update/rollback demonstration (§9 of
  the assignment); the cluster was rolled back to `1.0.0` afterwards, which
  is also what `k8s/deployment.yaml` declares.

```bash
docker pull rebecca16ouatt/msc-de1-flask-app:1.0.0
docker run -d -p 5000:5000 rebecca16ouatt/msc-de1-flask-app:1.0.0
curl http://localhost:5000/
```

## 8. Create the kind cluster

```bash
kind create cluster --config kind/kind-config.yaml --name msc-de1
kubectl get nodes -o wide
```

`kind/kind-config.yaml` defines 1 control-plane node and 2 worker nodes.

## 9. Deploy the Kubernetes manifests

```bash
kubectl apply -f k8s/namespace.yaml \
               -f k8s/configmap.yaml \
               -f k8s/deployment.yaml \
               -f k8s/service.yaml \
               -f k8s/network-policy.yaml

kubectl get pods -n msc-de1-project -o wide
```

## 10. Access and test the application

```bash
kubectl port-forward -n msc-de1-project svc/msc-de1-flask-app 8080:80

curl http://localhost:8080/
curl http://localhost:8080/items
curl -X POST -H "Content-Type: application/json" -d '{"name":"apple"}' http://localhost:8080/items
```

Distributed-systems behavior demonstrated (commands and captured output in
`evidence/kubernetes/`):
- **Replication & service discovery**: 2 pods scheduled on different worker
  nodes; `kubectl get endpoints` shows both pod IPs behind the Service.
- **Self-healing**: `kubectl delete pod <name>` → the Deployment
  controller creates a replacement automatically.
- **Scaling**: `kubectl scale deployment msc-de1-flask-app --replicas=3`,
  verified, then scaled back to 2.
- **Rolling update & rollback**: `kubectl set image ...:1.1.0` →
  `kubectl rollout status` / `rollout history`, then
  `kubectl rollout undo` back to the `1.0.0` revision.

## 11. Delete / clean up the local cluster

```bash
kubectl delete namespace msc-de1-project
kind delete cluster --name msc-de1
```

To also remove local Docker artifacts:

```bash
docker compose down
docker rmi rebecca16ouatt/msc-de1-flask-app:1.0.0 rebecca16ouatt/msc-de1-flask-app:latest rebecca16ouatt/msc-de1-flask-app:1.1.0
```

## 12. Security decisions and known limitations

- **Non-root everywhere**: enforced consistently in the Dockerfile (`USER
  appuser`), Compose (inherits the image user), and Kubernetes
  (`runAsNonRoot: true`, `runAsUser: 100`, `runAsGroup: 101` — matching the
  image's actual user).
- **Minimal image**: Alpine base + build tools (`pip`/`setuptools`/`wheel`)
  removed after install. Vulnerability scan: `security/vulnerability-scan.txt`
  (Trivy) — final result is 1 LOW finding (a Flask CVE about session-cache
  disclosure; not applicable here since this app never sets Flask sessions
  or cookies). SBOM: `security/sbom.cdx.json` (CycloneDX, via Syft).
- **Reduced privileges**: `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` in
  Kubernetes; `cap_drop: [ALL]` and `no-new-privileges:true` in Compose.
- **Read-only root filesystem**: enabled in both Compose and Kubernetes,
  with an `emptyDir`/`tmpfs` mount for `/tmp` since Python may otherwise
  attempt writes there.
- **Resource limits**: CPU/memory `requests` and `limits` set on the
  Deployment so the app cannot consume unbounded cluster resources.
- **NetworkPolicy limitation**: `k8s/network-policy.yaml` restricts ingress
  to the app's port from within the `msc-de1-project` namespace and egress
  to DNS only. `kind`'s default CNI (kindnet) does **not enforce**
  NetworkPolicy out of the box — the policy documents intended access but
  is not actively enforced unless a policy-aware CNI (e.g. Calico or
  Cilium) is installed, which was out of scope for the project timeline.
- **No secrets required**: the app has no credentials or external
  dependencies, so no Kubernetes `Secret` was needed; the only externalized
  configuration (`PORT`) uses a `ConfigMap`.

## Credits

Original application by Pan Luo — <https://github.com/ubc/flask-sample-app>
(MIT License, see `LICENSE`).
