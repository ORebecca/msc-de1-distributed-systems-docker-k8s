# MSc DE1: Distributed Systems Docker & Local Kubernetes Project

This repo contains my work for the Distributed Systems Docker/Kubernetes project: I took
the [UBC Flask Sample App](https://github.com/ubc/flask-sample-app) (a small Flask REST API
with no Dockerfile), containerized it, secured it, published it to Docker Hub, and deployed it
to a local `kind` Kubernetes cluster.

The point wasn't to change what the app does, just to wrap a clean and secure
containerization/orchestration workflow around it.

## 1. What's here

Rough flow of the project:

```
Flask app (logic unchanged)
     |  Dockerfile: non-root, alpine base, healthcheck
     v
Docker image --- docker compose for local dev
     |
     v
Docker Hub (rebecca16ouatt/msc-de1-flask-app)
     |
     v
kind cluster: 1 control-plane + 2 workers
     |
     v
Kubernetes: Namespace, ConfigMap, Deployment (2 replicas, probes,
resource limits, hardened securityContext), Service, NetworkPolicy
```

## 2. The starter application

Source: <https://github.com/ubc/flask-sample-app>. It's a small Flask API for managing a list
of items in memory, and it already came with a working unittest suite.

I made two small changes to the app itself (everything else was left as-is):

1. `run.py` now binds to `0.0.0.0` instead of Flask's default `127.0.0.1` (port is
   configurable via `PORT`). This was necessary; without it, the app isn't reachable from
   outside the container at all. Running it directly on the host still works the same.
2. Later on, for the rolling-update demo required by the assignment, I bumped the text
   returned by `/` to include a version marker, and updated the one test that checked that
   exact string.

## 3. Prerequisites

- Python 3.12+ if you want to run the app without Docker
- Docker Desktop
- `kind` (on Windows: `winget install Kubernetes.kind`)
- `kubectl`
- Trivy and Syft, but only if you want to re-run the security scans yourself

## 4. Running the original app (no Docker)

```bash
python -m venv venv
source venv/Scripts/activate   # Windows Git Bash; venv/bin/activate on Linux/macOS
pip install -r requirements.txt
python run.py
# -> http://localhost:5000

# separate terminal:
python -m unittest discover tests
```

I saved the output of this baseline run under `evidence/baseline/` before touching Docker at
all, since the assignment asks you to prove the app worked before containerizing it.

## 5. Building and running the Docker image

```bash
docker build -t rebecca16ouatt/msc-de1-flask-app:1.0.0 .
docker run -d --name msc-de1-flask-app -p 5000:5000 rebecca16ouatt/msc-de1-flask-app:1.0.0

curl http://localhost:5000/
curl http://localhost:5000/items
docker logs msc-de1-flask-app
docker exec msc-de1-flask-app id     # uid=100, not root

docker stop msc-de1-flask-app && docker rm msc-de1-flask-app
```

A few notes on the Dockerfile:

I started with `python:3.12-slim` and it worked fine, but a Trivy scan turned up 150
vulnerabilities (44 of them HIGH), almost all in Debian OS packages that this app doesn't even
use. Switching to `python:3.12-alpine` got that down to 0 OS-level findings and roughly halved
the image size. Details in `security/vulnerability-scan.txt`.

Other than that: `requirements.txt` gets copied and installed before the rest of the source so
Docker can cache that layer, the app runs as a dedicated non-root user (`appuser`, uid 100),
only port 5000 is exposed, and there's a `HEALTHCHECK` hitting `GET /`. I also strip
`pip`/`setuptools`/`wheel` after installing dependencies. They're build-time tools, not needed
once the image is built, and Trivy was flagging vulnerabilities in them too. Final image is
about 78MB, down from ~198MB with the Debian base.

## 6. Docker Compose

```bash
docker compose up -d
curl http://localhost:5000/
docker compose logs
docker compose down
```

`compose.yaml` locks things down a bit more for local testing: read-only root filesystem
(with `tmpfs` for `/tmp`, since Python occasionally wants to write there), all capabilities
dropped, `no-new-privileges`. No privileged mode, no Docker socket mount, no host networking.

## 7. Docker Hub

Image: **<https://hub.docker.com/r/rebecca16ouatt/msc-de1-flask-app>**

Tags pushed:
- `1.0.0`: what's actually deployed in `k8s/deployment.yaml`
- `latest`: same image as `1.0.0`
- `1.1.0`: only exists for the rolling-update/rollback demo below; the cluster was rolled back
  to `1.0.0` afterwards

```bash
docker pull rebecca16ouatt/msc-de1-flask-app:1.0.0
docker run -d -p 5000:5000 rebecca16ouatt/msc-de1-flask-app:1.0.0
curl http://localhost:5000/
```

## 8. Creating the kind cluster

```bash
kind create cluster --config kind/kind-config.yaml --name msc-de1
kubectl get nodes -o wide
```

`kind-config.yaml` sets up 1 control-plane node and 2 workers.

## 9. Deploying to Kubernetes

```bash
kubectl apply -f k8s/namespace.yaml \
               -f k8s/configmap.yaml \
               -f k8s/deployment.yaml \
               -f k8s/service.yaml \
               -f k8s/network-policy.yaml

kubectl get pods -n msc-de1-project -o wide
```

## 10. Accessing and testing it

```bash
kubectl port-forward -n msc-de1-project svc/msc-de1-flask-app 8080:80

curl http://localhost:8080/
curl http://localhost:8080/items
curl -X POST -H "Content-Type: application/json" -d '{"name":"apple"}' http://localhost:8080/items
```

I also went through the distributed-systems checks the assignment asks for (raw command
output is in `evidence/kubernetes/`):

- Both pods land on different worker nodes, and `kubectl get endpoints` shows both of them
  behind the Service.
- Deleted a pod manually, and the Deployment noticed and spun up a replacement on its own.
- Scaled from 2 to 3 replicas, checked it, scaled back down to 2.
- Rolled out `1.1.0` with `kubectl set image`, watched `rollout status`/`rollout history`,
  then rolled back to `1.0.0` with `kubectl rollout undo`.

## 11. Tearing it down

```bash
kubectl delete namespace msc-de1-project
kind delete cluster --name msc-de1
```

And if you want to remove the local Docker images too:

```bash
docker compose down
docker rmi rebecca16ouatt/msc-de1-flask-app:1.0.0 rebecca16ouatt/msc-de1-flask-app:latest rebecca16ouatt/msc-de1-flask-app:1.1.0
```

## 12. Security choices and limitations I'm aware of

- **Non-root, everywhere.** The Dockerfile switches to `appuser` before the app runs, Compose
  just inherits that, and the Kubernetes Deployment explicitly sets `runAsNonRoot: true` with
  `runAsUser: 100` / `runAsGroup: 101` to match.
- **Alpine + stripped build tools** got the vulnerability count down to a single LOW finding
  (see `security/vulnerability-scan.txt`): a Flask CVE about session-cache disclosure that
  doesn't actually apply here since the app never touches Flask sessions or cookies. SBOM is in
  `security/sbom.cdx.json` (CycloneDX, generated with Syft).
- `allowPrivilegeEscalation: false`, all Linux capabilities dropped, and
  `seccompProfile: RuntimeDefault` on the Kubernetes side; `cap_drop: [ALL]` and
  `no-new-privileges` in Compose.
- Read-only root filesystem in both Compose and Kubernetes (with a small writable `/tmp`).
- CPU/memory requests and limits are set on the Deployment so the pod can't eat unbounded
  cluster resources.
- The NetworkPolicy documents that only same-namespace traffic should reach the app on port
  5000, but I should flag that `kind`'s default networking (kindnet) doesn't actually enforce
  NetworkPolicy. You'd need something like Calico or Cilium installed for that to be real
  enforcement rather than just documentation, and I didn't have time to add that on top of
  everything else.
- No secrets needed anywhere: the app doesn't use any. The one piece of config (`PORT`) goes
  through a ConfigMap instead of being hard-coded.

## Credits

Original application by Pan Luo: <https://github.com/ubc/flask-sample-app> (MIT License, see
`LICENSE`).
