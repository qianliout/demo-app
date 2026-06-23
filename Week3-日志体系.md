# 运维实操笔记 —— Week 3 补充：日志体系

> 适用集群：OrbStack K8s (1 master + 1 worker, ARM64, v1.33.13)
> 前置条件：kube-prometheus-stack 已安装，Grafana 可访问

---

## 第一部分：安装策略

### Helm vs 裸 YAML

生产环境中常见做法：

| 组件 | 推荐方式 | 原因 |
|------|---------|------|
| **Loki** | Helm | 配置项多（存储、schema、限流、保留策略），Helm 模板化管理，一键升级/回滚。`grafana/loki` chart 仍在活跃维护（当前 v7.0.0）。 |
| **Promtail** | 裸 YAML（DaemonSet + ConfigMap） | 配置极简——就是一个 DaemonSet 读 `/var/log/pods` 推送到 Loki。`grafana/promtail` chart 已弃用。用 YAML 直接管理更透明，配合 ArgoCD/Flux 做 GitOps 很自然。 |

> Promtail 的继任者是 Grafana Alloy（仍在早期），新项目可以评估，旧项目继续用 Promtail YAML 足够。

---

## 第二部分：Promtail（裸 YAML 部署）

Promtail 以 DaemonSet 形式在每个节点运行，读取 `/var/log/pods` 下的容器日志推送 Loki。

### deploy/promtail.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: monitoring
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
    clients:
      - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
    positions:
      filename: /tmp/positions.yaml
    scrape_configs:
      - job_name: kubernetes-pods
        pipeline_stages:
          - cri: {}
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: __host__
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - replacement: /var/log/pods/*$1/*.log
            separator: /
            source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
            target_label: __path__
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      serviceAccountName: promtail
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: promtail
          image: grafana/promtail:3.5.1
          imagePullPolicy: IfNotPresent
          args:
            - -config.file=/etc/promtail/promtail.yaml
          volumeMounts:
            - name: config
              mountPath: /etc/promtail
            - name: pods
              mountPath: /var/log/pods
              readOnly: true
          env:
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 128Mi }
      volumes:
        - name: config
          configMap:
            name: promtail-config
        - name: pods
          hostPath:
            path: /var/log/pods
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail
subjects:
  - kind: ServiceAccount
    name: promtail
    namespace: monitoring
```

关键点：
- `tolerations` 使 DaemonSet 在 control-plane 节点也运行，采集系统组件日志
- `imagePullPolicy: IfNotPresent` 配合预导入镜像

```bash
kubectl apply -f deploy/promtail.yaml
kubectl wait --for=condition=ready pod -l app=promtail -n monitoring --timeout=120s
```

---

## 第三部分：Loki（Helm 部署）

### deploy/loki-values.yaml

```yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
    filesystem:
      chunks_directory: /var/loki/chunks
      rules_directory: /var/loki/rules
    bucketNames:
      chunks: chunks
      ruler: ruler
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  # 日志保留：7 天后自动删除
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
  limits_config:
    retention_period: 168h

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 5Gi
    storageClass: local-path

global:
  image:
    pullPolicy: IfNotPresent

# 禁用不需要的组件
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
minio:
  enabled: false
lokiCanary:
  enabled: false
gateway:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
test:
  enabled: false
```

关键点：
- `deploymentMode: SingleBinary` 单节点模式，适合学习/小规模
- `retention_period: 168h`（7 天），配合 `compactor.retention_enabled` 自动清理过期日志
- `persistence.storageClass: local-path` 必须显式指定
- 所有非必要组件 disabled，避免拉取额外镜像

### 镜像准备

节点 VM 不能直接访问 Docker Hub 时，从宿主机搬镜像：

```bash
# 在 Mac 宿主机上
docker pull grafana/loki:3.6.7 --platform linux/arm64
docker pull kiwigrid/k8s-sidecar:2.5.0 --platform linux/arm64
docker pull grafana/promtail:3.5.1 --platform linux/arm64

docker save grafana/loki:3.6.7 kiwigrid/k8s-sidecar:2.5.0 grafana/promtail:3.5.1 -o /tmp/log-images.tar

scp /tmp/log-images.tar k8s-master-01:/tmp/
scp /tmp/log-images.tar k8s-worker-01:/tmp/

ssh k8s-master-01 "sudo ctr -n k8s.io image import /tmp/log-images.tar"
ssh k8s-worker-01 "sudo ctr -n k8s.io image import /tmp/log-images.tar"
```

### 安装

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  --version 7.0.0 \
  -n monitoring \
  -f deploy/loki-values.yaml
```

### 验证

```bash
helm ls -n monitoring | grep loki
kubectl get pods -n monitoring -l 'app.kubernetes.io/name=loki'
```

预期：`loki-0 2/2 Running`。

---

## 第四部分：Grafana 集成

```bash
# 通过 Grafana API 添加 Loki 数据源
kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"Loki","type":"loki","url":"http://loki.monitoring.svc.cluster.local:3100","access":"proxy"}' \
  http://admin:admin123@localhost:3000/api/datasources
```

浏览器访问 Grafana → **Explore** → 数据源下拉选 **Loki**。

---

## 第五部分：LogQL 实战

```logql
# 查看 demo 命名空间所有日志
{namespace="demo"}

# 只看某个 Pod 的日志
{namespace="demo", pod=~"demo-app-.*"}

# 搜索包含 "error" 的日志（大小写不敏感）
{namespace="demo"} |~ "(?i)error"

# 只显示 stderr
{namespace="demo", stream="stderr"}

# 统计 5 分钟内每个 Pod 的日志行数
sum by (pod) (count_over_time({namespace="demo"}[5m]))

# 查看过去 1 小时的日志（Grafana Explore 右上角调整时间范围）
```

---

## 第六部分：Metrics vs Logs

| 维度 | Metrics（指标） | Logs（日志） |
|------|----------------|-------------|
| 采集组件 | Prometheus（Pull） | Promtail → Loki（Push） |
| 数据类型 | 数字（CPU %、请求数、延迟 ms） | 文本（stdout/stderr） |
| 查询语言 | PromQL | LogQL |
| Grafana 位置 | Dashboard Panel | Explore / Dashboard Logs Panel |
| 典型用途 | "Pod CPU 超过 80% 持续 5 分钟了" | "搜索最近 100 条含 timeout 的日志" |

---

## 第七部分：K8s 容器日志轮转

### 谁负责轮转？

```
应用 stdout/stderr
      │
      ▼
containerd（运行时）
  max_container_log_line_size = 16384  ← 只限制单行长度
  ❌ 不负责日志轮转
      │
      ▼
kubelet（容器日志管理器）
  containerLogMaxSize  — 单文件超过多大后轮转
  containerLogMaxFiles — 每个容器保留几个历史文件
```

### 配置

kubelet 默认值：`containerLogMaxSize: 10Mi`，`containerLogMaxFiles: 5`。

编辑 `/var/lib/kubelet/config.yaml`（两个节点都要做），在 `cgroupDriver` 后添加：

```yaml
containerLogMaxSize: "50Mi"
containerLogMaxFiles: 10
```

```bash
sudo systemctl restart kubelet
# 验证
sudo journalctl -u kubelet --since '1 min ago' --no-pager | grep "container_log_manager"
```

### 参数建议

| 场景 | containerLogMaxSize | containerLogMaxFiles |
|------|--------------------|--------------------|
| 开发/学习 | 10Mi（默认）| 5（默认）|
| 一般生产 | 50Mi | 10 |
| 高流量 | 100Mi | 20 |

> Promtail 通过 inode 跟踪文件，kubelet 轮转时旧文件被删除后自动停止读取，无需额外配置。

### 当前集群配置

| 节点 | containerLogMaxSize | containerLogMaxFiles |
|------|--------------------|--------------------|
| k8s-master-01 | 50Mi | 10 |
| k8s-worker-01 | 50Mi | 10 |

---

## 调试锦囊

### Promtail 权限错误

```bash
kubectl logs -n monitoring ds/promtail --tail=20
```

### Loki 查询返回空

1. 确认 Promtail 日志中有 `push success`
2. 调大 Grafana Explore 时间范围
3. 确认标签匹配：`{namespace="demo"}` 中的 namespace 是 K8s namespace 名称

### Loki 磁盘占用过高

```bash
# 检查 PVC 使用量
kubectl get pvc -n monitoring
```

当前已配置 `retention_period: 168h`（7 天），compactor 自动清理过期数据。

### 查看 Promtail 采集了哪些文件

```bash
kubectl logs -n monitoring ds/promtail | grep "tail routine: started"
```
