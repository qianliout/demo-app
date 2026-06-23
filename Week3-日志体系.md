# 运维实操笔记 —— Week 3 补充：日志体系

> 适用集群：OrbStack K8s (1 master + 1 worker, ARM64, v1.33.13)
> 前置条件：kube-prometheus-stack 已安装，Grafana 可访问
> 可以使用 ssh  k8s-master-01 进入master节点

***

## 第一部分：Grafana Loki + Promtail 日志收集

> Grafana 本身不收集日志，它是可视化面板。日志收集需要额外搭建 **Loki**（日志存储+查询引擎）+ **Promtail**（日志采集代理）。

### 架构

```
┌──────────────────┐
│   你的应用 Pod    │── stdout/stderr ──→ /var/log/pods/*.log
└──────────────────┘                            │
                                                ▼
┌──────────────────────────────────────────────────────┐
│  Promtail (DaemonSet — 每个节点跑一个)                │
│  ├── 自动发现 Pod 和容器                              │
│  ├── 给每条日志打上 namespace / pod / container 标签    │
│  └── 推送日志到 Loki ──────────────────────┐           │
└───────────────────────────────────────────┼───────────┘
                                            ▼
┌──────────────────────────────────────────────────────┐
│  Loki (单节点 Deployment)                             │
│  ├── 存储日志（本地 filesystem，5Gi）                   │
│  ├── 提供 LogQL 查询接口                               │
│  └── 作为 Grafana 数据源 ──────────┐                   │
└──────────────────────────────────┼───────────────────┘
                                   ▼
┌──────────────────────────────────────────────────────┐
│  Grafana → Explore → 选 Loki → LogQL 查询日志           │
│  可以和 Prometheus 指标放在同一个 Dashboard 里对照查看     │
└──────────────────────────────────────────────────────┘
```

### Phase 1: 拉取并导入镜像到节点

K8s 节点 VM 无法直接访问 Docker Hub，需要从宿主机搬镜像：

```bash
# 在 Mac 宿主机上
docker pull grafana/loki:3.6.7 --platform linux/arm64
docker pull grafana/promtail:3.5.1 --platform linux/arm64

docker save grafana/loki:3.6.7 grafana/promtail:3.5.1 -o /tmp/loki-images.tar

scp /tmp/loki-images.tar k8s-master-01:/tmp/
scp /tmp/loki-images.tar k8s-worker-01:/tmp/

ssh k8s-master-01 "sudo ctr -n k8s.io image import /tmp/loki-images.tar"
ssh k8s-worker-01 "sudo ctr -n k8s.io image import /tmp/loki-images.tar"
```

### Phase 2: 部署 Loki（日志存储 + 查询引擎）

**deploy/loki.yaml**：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: monitoring
data:
  loki.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
      grpc_listen_port: 9095
    common:
      instance_addr: 127.0.0.1
      path_prefix: /var/loki
      storage:
        filesystem:
          chunks_directory: /var/loki/chunks
          rules_directory: /var/loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory
    schema_config:
      configs:
        - from: 2024-01-01
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: loki_index_
            period: 24h
    limits_config:
      allow_structured_metadata: true
      volume_enabled: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
        - name: loki
          image: grafana/loki:3.6.7
          imagePullPolicy: IfNotPresent
          args:
            - -config.file=/etc/loki/loki.yaml
          ports:
            - containerPort: 3100
              name: http
          volumeMounts:
            - name: config
              mountPath: /etc/loki
            - name: data
              mountPath: /var/loki
          readinessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 512Mi }
      volumes:
        - name: config
          configMap:
            name: loki-config
        - name: data
          emptyDir:
            sizeLimit: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: monitoring
spec:
  ports:
    - port: 3100
      name: http
  selector:
    app: loki
```

```bash
kubectl apply -f deploy/loki.yaml
kubectl wait --for=condition=ready pod -l app=loki -n monitoring --timeout=120s
```

### Phase 3: 部署 Promtail（日志采集 DaemonSet）

Promtail 以 DaemonSet 形式在每个节点上运行，读取 `/var/log/pods` 下的容器日志并推送到 Loki。

**deploy/promtail.yaml**：

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

```bash
kubectl apply -f deploy/promtail.yaml
kubectl wait --for=condition=ready pod -l app=promtail -n monitoring --timeout=120s
```

### Phase 4: 在 Grafana 中添加 Loki 数据源

```bash
# 获取 Grafana admin 密码
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# 通过 Grafana API 添加 Loki 数据源（在 K8s 节点上执行）
kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"Loki","type":"loki","url":"http://loki.monitoring.svc.cluster.local:3100","access":"proxy"}' \
  http://admin:<密码>@localhost:3000/api/datasources
```

然后浏览器访问 Grafana → 左侧 **Explore** → 顶部数据源下拉选 **Loki** → 输入 LogQL 查询。

### Phase 5: LogQL 实战查询

```logql
# 查看 demo 命名空间所有日志
{namespace="demo"}

# 只看某个 Pod
{namespace="demo", pod=~"demo-app-.*"}

# 搜索包含 "error" 的日志（大小写不敏感）
{namespace="demo"} |~ "(?i)error"

# 只显示 stderr
{namespace="demo", stream="stderr"}

# 统计 5 分钟内每个 Pod 的日志行数
sum by (pod) (count_over_time({namespace="demo"}[5m]))

# 查看过去 1 小时日志（Grafana Explore 右上角可调时间范围）
# 或者通过 API 指定 start/end 参数
```

### 关键概念对比：Metrics vs Logs

| 维度         | Metrics（指标）               | Logs（日志）                          |
| ---------- | ------------------------- | --------------------------------- |
| 采集组件       | Prometheus（Pull 模式）       | Promtail → Loki（Push 模式）          |
| 数据类型       | 数字（CPU %、请求数、延迟 ms）       | 文本（stdout/stderr 输出）              |
| 查询语言       | PromQL                    | LogQL                             |
| 典型用途       | "Pod CPU 超过 80% 持续 5 分钟了" | "搜索最近 100 条包含 timeout 的日志"        |
| Grafana 位置 | Dashboard Panel           | Explore 页面 / Dashboard Logs Panel |

> **告警可以在哪里配置？** 当前笔记通过 `PrometheusRule` CRD 在 Prometheus 侧配置（YAML 管理、GitOps 友好），也可以在 **Grafana UI → Alerting → Alert rules → New alert rule** 手动创建。两者底层查询的都是 Prometheus PromQL，生产环境推荐 PrometheusRule（可版本管理）。

***

## 第二部分：K8s 容器日志轮转配置

### 日志轮转由谁负责？

```
应用 stdout/stderr
      │
      ▼
┌──────────────────────────────────────────────┐
│ containerd (运行时)                            │
│   max_container_log_line_size = 16384 (16KB)  │  ← 只限制单行长度
│   ❌ 不负责日志轮转                            │
└────────────────────┬─────────────────────────┘
                     │ 写入文件
                     ▼
┌──────────────────────────────────────────────┐
│ kubelet (容器日志管理器)                        │
│   containerLogMaxSize  — 单文件最大多大后轮转    │
│   containerLogMaxFiles — 每个容器保留几个历史文件 │
│                                               │
│   轮转规则: 到达上限 → 0.log → 1.log → ...       │
│   日志路径: /var/log/pods/<ns>_<pod>_<uid>/    │
│                       <container>/0.log       │
└──────────────────────────────────────────────┘
```

### 默认值

kubelet 不显式配置时，使用硬编码默认值：

| 参数                     | 默认值    | 含义                           |
| ---------------------- | ------ | ---------------------------- |
| `containerLogMaxSize`  | `10Mi` | 单个日志文件超过 10Mi 就轮转            |
| `containerLogMaxFiles` | `5`    | 每个容器最多保留 5 个历史文件（当前 + 4 个轮转） |

### 磁盘占用上限

```
max_per_container = containerLogMaxSize × containerLogMaxFiles
                   = 50Mi × 10 = 500Mi

worst_case = 总容器数 × max_per_container
```

### 配置方法

编辑 kubelet 配置文件（两个节点都要做）：

```bash
# 备份
sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak

# 编辑，在 cgroupDriver 下方添加
sudo vi /var/lib/kubelet/config.yaml
```

在 `cgroupDriver: systemd` 之后添加：

```yaml
containerLogMaxSize: "50Mi"
containerLogMaxFiles: 10
```

然后重启 kubelet：

```bash
sudo systemctl restart kubelet
```

验证配置已加载：

```bash
sudo journalctl -u kubelet --since '1 min ago' --no-pager | grep "container_log_manager"
# 看到 "Initializing container log rotate workers" 说明生效
```

### 参数建议

| 场景    | containerLogMaxSize | containerLogMaxFiles |
| ----- | ------------------- | -------------------- |
| 开发/学习 | 10Mi（默认）            | 5（默认）                |
| 一般生产  | 50Mi                | 10                   |
| 高流量应用 | 100Mi               | 20                   |

### 对 Promtail 的影响

Promtail 通过 inode 跟踪文件，kubelet 轮转时旧文件被删除，Promtail 自动停止读取已删除的文件，对新文件继续跟踪。**不需要额外配置**。

### 当前集群配置

| 节点            | 配置                                                        |
| ------------- | --------------------------------------------------------- |
| k8s-master-01 | `containerLogMaxSize: "50Mi"`, `containerLogMaxFiles: 10` |
| k8s-worker-01 | `containerLogMaxSize: "50Mi"`, `containerLogMaxFiles: 10` |

***

## 调试锦囊

### 问题：Promtail 启动报 permission denied

```bash
# Promtail 需要读取 /var/log/pods，确保 hostPath 有正确权限
kubectl logs -n monitoring ds/promtail --tail=20
```

### 问题：Loki 查询返回空结果

1. 确认 Promtail 正在推送：检查 Promtail 日志中有 `"msg"="push success"`
2. 确认时间范围：Loki 默认查询范围可能太窄，调大 Grafana Explore 右上角的时间范围
3. 确认标签匹配：`{namespace="demo"}` 中的 namespace 必须是 K8s namespace 名称

### 问题：Loki 磁盘占用过高

Loki 使用 emptyDir 存储，重启 Pod 数据会丢失。生产环境应配置持久化存储：

```yaml
# 将 emptyDir 替换为 PVC
persistentVolumeClaim:
  claimName: loki-data
```

### 问题：如何查看 Promtail 采集了哪些文件？

```bash
kubectl logs -n monitoring ds/promtail | grep "tail routine: started"
```

