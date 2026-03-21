# Grafana Monitoring

The cluster runs a Prometheus + Grafana monitoring stack deployed via `deploy-monitoring.sh`.

## Access

Grafana is exposed as a NodePort service on port **30300**, accessible from any machine on the network:

```
http://<any-node-ip>:30300
```

Login: **admin** / **prom-operator**

## Dashboards

Pre-installed dashboards (under Dashboards → Browse):

| Dashboard | What it shows |
|-----------|---------------|
| Node Exporter / Nodes | Per-core CPU usage, load averages, thread counts |
| K8s / Compute Resources / Cluster | Cluster-wide CPU and memory overview |
| K8s / Compute Resources / Node (Pods) | Per-pod CPU/memory breakdown on each node |

## CLI Checks

```bash
kubectl top nodes
kubectl top pods -A
```

## Redeploying

To redeploy or update the monitoring stack:

```bash
bash deploy-monitoring.sh
```

The script uses `helm upgrade --install`, so it's safe to re-run.

## Removing

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
```
