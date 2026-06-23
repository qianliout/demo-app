# 运维实操笔记 —— Week 3：CI/CD + 监控体系

> 适用集群：OrbStack K8s (1 master + 1 worker, ARM64, v1.33.13)
> 前置条件：Helm v3.19.0 已安装，kubectl 可用，SSH 到 master 节点


---

## 第一部分：CI/CD Pipeline（GitHub Actions → Docker → K8s）

### 目标

代码 push → GitHub Actions 自动构建 Docker 镜像 → 推送到镜像仓库 → 自动部署到 K8s

### 整体架构

```
GitHub Repo (你的后端代码)
    │
    │  git push
    ▼
GitHub Actions
    ├── Step 1: Checkout 代码
    ├── Step 2: Docker Build (跨架构构建: linux/arm64)
    ├── Step 3: Push 到 Docker Hub / 阿里云 ACR
    └── Step 4: kubectl set image 更新 Deployment
```

---

### Phase 1: 准备 Docker Hub 仓库（10 分钟）

1. 去 https://hub.docker.com 注册账号（如果没有）
2. 创建一个 Public Repository，名字比如 `demo-app`
3. 在本地生成 Access Token：
   - Docker Hub → Account Settings → Security → New Access Token
   - 记下 token，只显示一次

---

### Phase 2: 在 K8s 集群上创建 Registry Secret

```bash
ssh k8s-master-01

# 创建命名空间
kubectl create namespace demo

# 创建拉取镜像用的 secret（换成你自己的 Docker Hub 用户名和 token）
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=docker.io \
  --docker-username=你的DockerHub用户名 \
  --docker-password=你的AccessToken \
  -n demo

# 验证
kubectl get secret dockerhub-secret -n demo
```

---

### Phase 3: 准备示例应用代码

在本地 Mac 上，创建一个简单的 Go Web 服务：

```bash
# 在你的 Mac 上（不是 K8s 节点）
mkdir -p ~/projects/demo-app
cd ~/projects/demo-app

# 初始化 Go module
go mod init github.com/你的GitHub用户名/demo-app
```

**main.go**：

```go
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func handler(w http.ResponseWriter, r *http.Request) {
    hostname, _ := os.Hostname()
    fmt.Fprintf(w, "Hello from %s (version: %s)\n", hostname, os.Getenv("APP_VERSION"))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
}

func main() {
    http.HandleFunc("/", handler)
    http.HandleFunc("/health", healthHandler)
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    log.Printf("Listening on :%s", port)
    log.Fatal(http.ListenAndServe(":"+port, nil))
}
```

---

### Phase 4: 编写 Makefile 和 Dockerfile（构建与镜像解耦）

**设计思路**：运维中常见模式——Makefile 负责编译，Dockerfile 只负责打包运行。两者解耦，CI 里先 `make build` 再 `docker build`。

**Makefile**（放在项目根目录）：

```makefile
APP_NAME    := demo-app
CMD_DIR     := cmd
OUTPUT_DIR  := bin
GO          := go

CGO_ENABLED ?= 0
GOOS        ?= linux
GOARCH      ?= arm64

OUTPUT := $(OUTPUT_DIR)/$(APP_NAME)

.PHONY: all build clean run help

all: build

## build: 编译 Go 二进制文件 (linux/arm64)
build:
	@mkdir -p $(OUTPUT_DIR)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) \
		$(GO) build -v -o $(OUTPUT) ./$(CMD_DIR)/
	@echo "✅ Build done: $(OUTPUT) ($(GOOS)/$(GOARCH))"

## build-amd64: 交叉编译为 amd64
build-amd64:
	$(MAKE) build GOARCH=amd64

## build-local: 在 Mac 本地编译（用于测试）
build-local:
	@mkdir -p $(OUTPUT_DIR)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=darwin GOARCH=arm64 \
		$(GO) build -v -o $(OUTPUT_DIR)/$(APP_NAME)-local ./$(CMD_DIR)/

## run: 本地编译并启动
run: build-local
	PORT=8080 ./$(OUTPUT_DIR)/$(APP_NAME)-local

## clean: 清理
clean:
	rm -rf $(OUTPUT_DIR)
```

**Dockerfile**（放在 `deploy/` 目录下，单阶段构建）：

```dockerfile
FROM ubuntu:24.04

# 安装运行时依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 复制 make build 产出的二进制
COPY bin/demo-app .

# 非 root 运行
RUN useradd -r -s /bin/false appuser && \
    chown appuser:appuser /app/demo-app
USER appuser

EXPOSE 8080
CMD ["./demo-app"]
```

**.dockerignore**：

```
.git
go.sum
bin/
Dockerfile
.dockerignore
```

**完整构建流程**：

```bash
cd /Users/liuqianli/work/golang/src/demo-app

# Step 1: 编译 Go 二进制
make build
# 产物: bin/demo-app (linux/arm64, 静态链接)

# Step 2: 构建 Docker 镜像
docker build -t demo-app:latest -f deploy/Dockerfile .

# Step 3: 本地验证
docker run --rm -p 8080:8080 demo-app:latest
# 另一个终端: curl http://localhost:8080/health
```

> **与之前笔记的区别**：
> - 不再使用 `golang:alpine` 多阶段构建，改为 **本地编译 + Ubuntu 单阶段打包**
> - 基础镜像 `ubuntu:24.04` 替代 `alpine:3.20`
> - 二进制编译由 Makefile 统一管理，可交叉编译 arm64/amd64
> - 增加 `appuser` 非 root 用户，遵循安全最佳实践
> - 优势：构建镜像更快（无需每次在容器内 go build），CI 里编译和打包可独立控制

---

### Phase 5: 编写 K8s 部署清单

在项目目录的 `deploy/` 文件夹下创建 K8s 部署清单：

**deploy/deployment.yaml**：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      imagePullSecrets:
        - name: dockerhub-secret
      containers:
        - name: demo-app
          image: 你的DockerHub用户名/demo-app:latest
          ports:
            - containerPort: 8080
          env:
            - name: APP_VERSION
              value: "latest"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app-svc
  namespace: demo
spec:
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
```

---

### Phase 6: GitHub Actions 流水线（适配 Makefile + Docker 分离模式）

在项目目录创建 `.github/workflows/deploy.yml`：

```yaml
name: Build and Deploy

on:
  push:
    branches:
      - main

env:
  DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
  IMAGE_NAME: 你的DockerHub用户名/demo-app

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.25'

      # Step 1: 用 Makefile 编译 Go 二进制（amd64 + arm64 都需要）
      - name: Build binary (arm64)
        run: make build GOARCH=arm64

      - name: Build binary (amd64)
        run: make build GOARCH=amd64 OUTPUT_DIR=bin-amd64

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      # Step 2: Docker 构建并推送多架构镜像
      # 注意：这里需要在 deploy/Dockerfile 中把 COPY bin/demo-app 改为 COPY bin-${TARGETARCH}/demo-app
      # 或者使用 buildx 的 --platform 分别构建
      - name: Build and push multi-arch image
        run: |
          # arm64 镜像
          docker build -f deploy/Dockerfile -t ${{ env.IMAGE_NAME }}:latest-arm64 .
          docker push ${{ env.IMAGE_NAME }}:latest-arm64
          # amd64 镜像（如果集群是纯 arm64 则不需要）
          # docker build -f deploy/Dockerfile -t ${{ env.IMAGE_NAME }}:latest-amd64 .
          # docker push ${{ env.IMAGE_NAME }}:latest-amd64

      - name: Set up kubectl
        uses: azure/setup-kubectl@v4

      - name: Set up kubeconfig
        run: |
          mkdir -p $HOME/.kube
          echo "${{ secrets.KUBE_CONFIG }}" | base64 -d > $HOME/.kube/config

      - name: Deploy to K8s
        run: |
          kubectl set image deployment/demo-app \
            demo-app=${{ env.IMAGE_NAME }}:latest-arm64 \
            -n demo
          kubectl rollout status deployment/demo-app -n demo --timeout=120s
```

> **与之前版本的区别**：
> - 不再使用 `docker/build-push-action` 的 platforms 参数在容器内编译
> - 改为 `make build GOARCH=arm64` 本地编译 + `docker build` 打包
> - Go 交叉编译比在 Docker 内编译更快，且不受 QEMU 模拟性能影响
> - 如果你的集群是纯 arm64（OrbStack），只需构建 arm64 镜像即可

---

### Phase 7: 配置 GitHub Secrets

在 GitHub 仓库的 Settings → Secrets and variables → Actions 中，添加以下 Secrets：

| Secret 名 | 值 |
|-----------|-----|
| `DOCKERHUB_USERNAME` | 你的 Docker Hub 用户名 |
| `DOCKERHUB_TOKEN` | 你的 Docker Hub Access Token |
| `KUBE_CONFIG` | 你的 kubeconfig 的 base64 编码 |

**获取 KUBE_CONFIG**：

```bash
# 在 Mac 上执行
kubectl config view --raw | base64 | pbcopy
# 或从 ~/.kube/config 获取：
cat ~/.kube/config | base64 | pbcopy
# 粘贴到 GitHub Secret KUBE_CONFIG 中
```

> ⚠️ **安全提醒**：生产环境不要直接把 kubeconfig 放进 GitHub。应该使用 GitHub Actions 的 OIDC + 云厂商 RBAC 或者单独创建一个低权限 ServiceAccount。

---

### Phase 8: 推到 GitHub 验证全流程

```bash
# 在本地 Mac 上
cd ~/projects/demo-app

git init
git add .
git commit -m "init: demo app with CI/CD"

# 创建 GitHub 仓库后
git remote add origin https://github.com/你的用户名/demo-app.git
git branch -M main
git push -u origin main

# 推送后去 GitHub Actions 页面看流水线执行
```

**验证 K8s 部署结果**：

```bash
ssh k8s-master-01

kubectl get pods -n demo -w          # 等 Pod Ready
kubectl get svc -n demo              # 拿到 ClusterIP

# 在集群内部测试
kubectl run -it --rm curl-test --image=curlimages/curl:latest -n demo -- sh
# 进去后执行：
curl http://demo-app-svc
curl http://demo-app-svc/health
exit
```

---

## 第二部分：Prometheus + Grafana 监控体系

### 目标

搭建完整的监控体系，覆盖：集群指标 → 应用指标 → 可视化 → 告警通知

### 架构

```
                    ┌──────────────┐
                    │  Alertmanager │ ──→ 钉钉/飞书 通知
                    └──────▲───────┘
                           │ 告警规则触发
                    ┌──────┴───────┐
                    │  Prometheus   │
                    └──▲────────▲───┘
                       │        │
              ┌────────┘        └─────────┐
              │ ServiceMonitor              │ node_exporter
              │ (应用指标)                   │ (节点指标)
              ▼                            ▼
     ┌────────────────┐         ┌─────────────────┐
     │   你的应用 Pod  │         │  kubelet 内置指标│
     └────────────────┘         │  cadvisor 容器指标│
                                └─────────────────┘

                    ┌──────────────┐
                    │   Grafana    │ ──→ 可视化 Dashboard
                    └──────────────┘
```

---

### Step 1: 安装 metrics-server（必须先装）

Prometheus 的一部分数据依赖 metrics-server。没有它，HPA 也无法工作。

```bash
ssh k8s-master-01

# 添加 metrics-server Helm repo
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

# 安装（注意：OrbStack 是自签证书，需要跳过 TLS 校验）
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --set args[1]="--kubelet-preferred-address-types=InternalIP"

# 等待就绪
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=metrics-server \
  -n kube-system --timeout=120s

# 验证 — 这个命令现在应该能输出 CPU/内存数据
kubectl top nodes
kubectl top pods -A
```

期望输出类似：

```
NAME            CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
k8s-master-01   250m         2%     2048Mi          12%
k8s-worker-01   100m         1%     1024Mi          6%
```

> 如果 `kubectl top` 仍然失败，等 1-2 分钟再试（metrics-server 需要采集周期）。

---

### Step 2: 安装 kube-prometheus-stack（一键安装全家桶）

这是 Prometheus 社区的 Helm Chart，一次装好 Prometheus + Grafana + Alertmanager + node_exporter。

```bash
ssh k8s-master-01

# 添加 Prometheus 社区 Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 创建监控命名空间
kubectl create namespace monitoring

# 安装 kube-prometheus-stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=admin123 \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30900 \
  --wait \
  --timeout 10m
```

> ⚠️ **常见踩坑：`--wait` 一直卡住没输出**
>
> **现象**：执行 `helm install` 后终端没有任何输出，一直挂住。
>
> **根因**：`--wait` 会等待所有 Pod Ready 才返回。如果某个 Pod 卡在 `ImagePullBackOff`（比如 K8s 节点 VM 访问 Docker Hub 超时/被墙），Helm 就永远等不到结束。
>
> **快速定位**：另开一个终端：
> ```bash
> ssh k8s-master-01
> kubectl get pods -n monitoring          # 找到状态不是 Running 的 Pod
> kubectl describe pod <问题Pod> -n monitoring | tail -20   # 看 Events
> ```
>
> **我们的实战案例**：Grafana Pod 卡在 `ImagePullBackOff`，Events 里显示：
> ```
> Failed to pull image "docker.io/grafana/grafana:13.0.2":
>   tls: failed to verify certificate: x509: certificate is valid for *.facebook.com...
>   → 说明 Docker Hub DNS/证书被污染（国内网络环境常见）
> ```
>
> **补救方案（适用于单次/少量镜像拉不下来）**——从宿主机"搬"镜像进节点：
> ```bash
> # 在 Mac 宿主机上（宿主机网络正常能拉 Docker Hub）
> docker pull grafana/grafana:13.0.2 --platform linux/arm64
> docker save grafana/grafana:13.0.2 -o /tmp/grafana.tar
> scp /tmp/grafana.tar k8s-master-01:/tmp/
> scp /tmp/grafana.tar k8s-worker-01:/tmp/
>
> # 在 K8s 节点上导入
> ssh k8s-master-01 "sudo ctr -n k8s.io image import /tmp/grafana.tar"
> ssh k8s-worker-01 "sudo ctr -n k8s.io image import /tmp/grafana.tar"
>
> # 删除旧 Pod 让它重建（从本地镜像读取）
> kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
> ```
>
> **永久方案**——给 containerd 配置 Docker Hub 镜像加速器（对所有镜像生效）：
> ```bash
> ssh k8s-master-01
> sudo mkdir -p /etc/containerd/certs.d/docker.io
> sudo tee /etc/containerd/certs.d/docker.io/hosts.toml << 'EOF'
> server = "https://docker.io"
>
> [host."https://docker.m.daocloud.io"]
>   capabilities = ["pull", "resolve"]
> EOF
> sudo systemctl restart containerd
>
> # worker 节点也做一遍
> ssh k8s-worker-01 "sudo mkdir -p /etc/containerd/certs.d/docker.io"
> ssh k8s-worker-01 "sudo tee /etc/containerd/certs.d/docker.io/hosts.toml << 'EOF'
> server = \"https://docker.io\"
>
> [host.\"https://docker.m.daocloud.io\"]
>   capabilities = [\"pull\", \"resolve\"]
> EOF"
> ssh k8s-worker-01 "sudo systemctl restart containerd"
> ```
> ⚠️ 镜像加速器也可能不稳定。如果配置后依然 `ImagePullBackOff`，就用上面 `docker save → ctr import` 兜底。

> ⚠️ 如果拉镜像报错 `exec format error` 说明镜像没有 ARM64 版本。执行下面的诊断命令：

```bash
# 查看哪个 Pod 拉镜像失败
kubectl get pods -n monitoring
kubectl describe pod <失败的pod名> -n monitoring | tail -20
```

---

### Step 3: 访问 Grafana

```bash
# 确认服务已启动
kubectl get svc -n monitoring

# 因为用了 NodePort，直接用节点 IP 访问
# 你的 master 节点 IP 是 192.168.139.167
echo "Grafana: http://192.168.139.167:30300"
echo "Prometheus: http://192.168.139.167:30900"
```

**Grafana 登录信息**：
- 用户名：`admin`
- 密码：`admin123`

**首次进入后**：
1. 登录后会提示改密码（可以先不改）
2. 左侧菜单 → Connections → Data Sources → 找到自动配好的 Prometheus → 点击 "Test" 确认连通

---

### Step 4: 探索 Grafana 自带 Dashboard

kube-prometheus-stack 自带了很多 Dashboard：

1. **Kubernetes / Compute Resources / Pod** — 看 Pod CPU/内存使用
2. **Kubernetes / Compute Resources / Node** — 看节点资源
3. **Kubernetes / Compute Resources / Namespace (Pods)** — 按命名空间聚合
4. **Kubernetes / API Server** — API Server 监控
5. **Node Exporter / Nodes** — 节点级系统指标（磁盘、网络、负载）

进入方式：Grafana 左侧菜单 → Dashboards → Browse → 搜索 "Kubernetes"

**每个都点进去看一眼**，这是你入职后天天打交道的界面。

---

### Step 5: 写你的第一条 PromQL

进入 Grafana 左侧 → Explore → 选择 Prometheus 数据源，逐条执行以下 PromQL：

```promql
# 1. 查看所有 Pod 的 CPU 使用率（占 request 的百分比）
sum by (pod) (
  rate(container_cpu_usage_seconds_total{container!=""}[5m])
) / 
sum by (pod) (
  kube_pod_container_resource_requests{resource="cpu"}
) * 100

# 2. 查看所有 Pod 的内存使用（MB）
sum by (pod) (container_memory_usage_bytes{container!=""}) / 1024 / 1024

# 3. 查看节点的 CPU 使用率
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 4. 查看节点磁盘使用率
100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100)

# 5. 查看 namespace 下的 Pod 数量
count by (namespace) (kube_pod_info)

# 6. 查看 Pod 重启次数
kube_pod_container_status_restarts_total > 0

# 7. 查看 demo 命名空间下 demo-app 的请求延迟（需要应用暴露 metrics，后面配置）
# 先留个坑 — rate(http_request_duration_seconds_sum[5m])
```

> **运维面试高频 PromQL**：`rate()` vs `irate()` 的区别？`rate()` 是区间平均速率，`irate()` 是区间内最后两个点的瞬时速率。`rate()` 适合告警，`irate()` 适合看突发尖刺。

---

### Step 6: 创建你的第一个自定义 Dashboard

1. Grafana 左侧 → Dashboards → New → New Dashboard → Add visualization
2. Data source 选 Prometheus
3. 在 Metrics browser 中输入：

```promql
# 显示 demo 命名空间每个 Pod 的 CPU 使用率
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="demo", container!=""}[5m])
)
```

4. Panel 选项：
   - Title: `Demo App - CPU Usage`
   - Unit: `percent (0.0-1.0)` 然后选 `Percent (0-100)`
   - Legend: `{{pod}}`

5. 点 Apply → 再点 Save dashboard，命名 `My Demo Dashboard`

再添加一个 Panel —— 内存使用：

```promql
sum by (pod) (
  container_memory_working_set_bytes{namespace="demo", container!=""}
) / 1024 / 1024
```

Unit 选 `Data → megabytes`。

---

### Step 7: 配置告警规则 → Alertmanager → 飞书通知

#### 7.1 理解 PrometheusRule CRD

kube-prometheus-stack 用 PrometheusRule CRD 来管理告警规则。先看自带的规则：

```bash
kubectl get prometheusrule -n monitoring
```

#### 7.2 创建自定义告警规则

创建文件 `demo-alert.yaml`：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: demo-app-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # 这个 label 很关键，确保被 Prometheus 选中
spec:
  groups:
    - name: demo-app
      rules:
        # 告警 1: Pod 数量不足
        - alert: DemoAppPodDown
          expr: |
            sum(kube_pod_info{namespace="demo", pod=~"demo-app-.*"}) < 2
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Demo App 可用 Pod 数量 {{ $value }} 低于预期"
            description: "demo-app 的 Pod 数低于 2，可能发生了故障"

        # 告警 2: Pod CPU 使用率超过 80%（持续 5 分钟）
        - alert: DemoAppHighCPU
          expr: |
            sum by (pod) (
              rate(container_cpu_usage_seconds_total{namespace="demo", pod=~"demo-app-.*", container!=""}[5m])
            ) /
            sum by (pod) (
              kube_pod_container_resource_requests{namespace="demo", pod=~"demo-app-.*", resource="cpu"}
            ) > 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} CPU 使用率超过 80%"
            description: "当前使用率: {{ $value | humanizePercentage }}"

        # 告警 3: Pod 频繁重启
        - alert: DemoAppFrequentRestart
          expr: |
            rate(kube_pod_container_status_restarts_total{namespace="demo", pod=~"demo-app-.*"}[15m]) > 0
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} 正在频繁重启"
```

```bash
kubectl apply -f demo-alert.yaml
kubectl get prometheusrule -n monitoring demo-app-alerts
```

> **PrometheusRule 是什么？为什么需要 kubectl apply？**
>
> kube-prometheus-stack 通过 `PrometheusRule` CRD 管理告警规则。你只需要写好 YAML 然后 `kubectl apply`，Prometheus Operator 会自动发现新的 PrometheusRule 资源，并将其中的规则注入到 Prometheus 配置中。**全程不需要手动编辑 Prometheus 的配置文件。**
>
> 流程：`kubectl apply demo-alert.yaml` → Prometheus Operator 检测到 PrometheusRule → 自动热加载到 Prometheus → Prometheus UI 的 Alerts 页面可见。
>
> 关键点：`metadata.labels` 中必须有 `release: kube-prometheus-stack`，这个 label 让 Operator 知道这个规则属于哪个 Prometheus 实例。

#### 7.3 验证告警规则生效

```bash
# 端口转发访问 Prometheus UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 --address=0.0.0.0 &

# 浏览器访问 http://localhost:9090 → Alerts → 找到 demo-app 分组
# 或者命令行
curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.labels.alertname | startswith("DemoApp"))'
```

> **「验证告警规则生效」具体操作和含义**
>
> 进入 Prometheus UI 的 **Alerts** 页面（`http://localhost:9090/alerts`），搜索 `DemoApp`，会看到每条告警规则及其状态：
>
> | 状态 | 含义 |
> |------|------|
> | **Inactive**（绿色） | 规则已加载，但条件未满足。这是正常运行时的状态。 |
> | **Pending**（黄色） | 条件已满足，但还没达到 `for: 2m` 的持续时长。 |
> | **Firing**（红色） | 条件持续满足超过 `for` 时长，告警已触发并发送到 Alertmanager。 |
>
> **如何验证它真的能触发**：
> ```bash
> # 故意缩容到 0，制造 Pod 不足的故障
> kubectl scale deployment demo-app -n demo --replicas=0
> # 等 2 分钟后刷新 Prometheus Alerts 页面，DemoAppPodDown 会从 Inactive → Firing
> # 恢复：
> kubectl scale deployment demo-app -n demo --replicas=2
> ```

#### 7.4 配置飞书告警通知（可选）

Alertmanager → 飞书 的流程：

1. 飞书群 → 群设置 → 群机器人 → 添加 Webhook 机器人
2. 获取 webhook URL

然后修改 Alertmanager 配置：

```bash
# 查看当前 Alertmanager 配置
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

创建一个自定义的 AlertmanagerConfig：

```yaml
# webook-alertmanager-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-kube-prometheus-stack-alertmanager
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
      receiver: 'feishu-webhook'
    receivers:
      - name: 'feishu-webhook'
        webhook_configs:
          - url: 'https://open.feishu.cn/open-apis/bot/v2/hook/你的webhook-key'
            send_resolved: true
    inhibit_rules:
      - source_match:
          severity: 'critical'
        target_match:
          severity: 'warning'
        equal: ['alertname']
```

> **AlertmanagerConfig 的作用是什么？**
>
> Prometheus 负责**发现故障**（生成告警），Alertmanager 负责**通知**（告警发给谁、怎么发、多久发一次）。两者的分工：
>
> ```
> Prometheus 产生告警
>       │
>       ▼
> Alertmanager
>   ├── 分组（group_by）：同一类告警合并成一条消息，避免消息轰炸
>   ├── 抑制（inhibit）：如果 critical 告警已触发，抑制同类的 warning 级别
>   ├── 静默（silence）：手动暂停某个告警（比如计划内维护窗口）
>   └── 路由（route）：决定发给哪个接收器（飞书 / 钉钉 / 邮件）
>       │
>       ▼
>   飞书 Webhook → 群消息通知
> ```
>
> 配置中各字段的含义：
>
> | 字段 | 作用 |
> |------|------|
> | `group_by: ['alertname']` | 同名告警合并，避免 2 个 Pod 同时挂掉时收到 2 条消息 |
> | `group_wait: 10s` | 第一次触发后等待 10s，收集同组内的其他告警一起发送 |
> | `group_interval: 10s` | 同一组已发过通知后，新告警加入时的发送间隔 |
> | `repeat_interval: 1h` | 告警持续未恢复时，重复发送的间隔（1h 一次，避免刷屏） |
> | `send_resolved: true` | 告警恢复后也发送通知，让你知道故障已解除 |
>
> **一句话总结**：`PrometheusRule` 定义「什么时候告警」，`Alertmanager` 定义「告警后怎么通知」。

```bash
kubectl apply -f webhook-alertmanager-config.yaml
# Alertmanager 会自动热加载配置
```

---

### Step 8: 让应用暴露 Prometheus 指标（应用监控）

目前为止你监控的都是基础设施。要让 Prometheus 采集**应用自身的指标**（请求量、延迟、错误率），需要：

#### 8.1 修改 Go 应用，添加 Prometheus 指标端点

在你的 `main.go` 中集成 `prometheus/client_golang`：

```go
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
    httpRequestsTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )
    httpRequestDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )
)

func init() {
    prometheus.MustRegister(httpRequestsTotal)
    prometheus.MustRegister(httpRequestDuration)
}

func metricsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
        next.ServeHTTP(rw, r)
        duration := time.Since(start).Seconds()
        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, fmt.Sprintf("%d", rw.statusCode)).Inc()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
    })
}

type responseWriter struct {
    http.ResponseWriter
    statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

func handler(w http.ResponseWriter, r *http.Request) {
    hostname, _ := os.Hostname()
    time.Sleep(time.Duration(10+time.Now().UnixMilli()%50) * time.Millisecond)
    fmt.Fprintf(w, "Hello from %s (version: %s)\n", hostname, os.Getenv("APP_VERSION"))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/", handler)
    mux.HandleFunc("/health", healthHandler)
    mux.Handle("/metrics", promhttp.Handler())

    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    log.Printf("Listening on :%s", port)
    log.Fatal(http.ListenAndServe(":"+port, metricsMiddleware(mux)))
}
```

同时修改 `k8s/deployment.yaml`，给 Pod 添加 annotations：

```yaml
spec:
  template:
    metadata:
      labels:
        app: demo-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
```

---

> **📋 日志收集（Loki + Promtail）已拆分为独立笔记** → 见 [Week3-日志体系.md](Week3-日志体系.md)
> 
> 内容包括：Loki/Promtail 部署架构、完整 YAML、Grafana 集成、LogQL 查询、kubelet 日志轮转配置。

---


花 30 分钟故意制造问题，练习用 Grafana + Prometheus + kubectl 定位：

| 场景 | 怎么制造 | 怎么看 |
|------|---------|--------|
| **Pod CPU 高** | `kubectl run stress --image=polinux/stress -- stress --cpu 2` | Grafana Pod CPU Dashboard 会飙高 → 触发 HighCPU 告警 |
| **Pod 挂掉** | `kubectl scale deployment demo-app -n demo --replicas=0` | Prometheus `DemoAppPodDown` 告警触发 |
| **内存泄漏** | `kubectl run mem-leak --image=polinux/stress -- stress --vm 1 --vm-bytes 500M` | Grafana Node Memory Dashboard |
| **节点 NotReady** | 模拟不了就不模拟，但要记住：先 `describe node` 看 Conditions，再 `journalctl -u kubelet` |

---

## Step 10: 清理

```bash
# 删掉压力测试 Pod
kubectl delete pod stress mem-leak --force 2>/dev/null

# 卸载监控栈
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring

# 卸载 metrics-server
helm uninstall metrics-server -n kube-system

# 删掉 demo 应用
kubectl delete namespace demo
```

---

## 本周学习检验清单（PASS 条件）

在周五下班前，确保你能做到以下 **8 件事**：

- [ ] 1. 从零在 K8s 上装好 metrics-server + kube-prometheus-stack，Grafana 可访问
- [ ] 2. 在 Grafana 里浏览至少 5 个自带 Dashboard（Pod/Node/Namespace/API Server/Node Exporter）
- [ ] 3. 手写 5 条 PromQL，能解释每条的返回结果
- [ ] 4. 创建一个自定义 Dashboard，包含 CPU 和内存两个 Panel
- [ ] 5. 让 CI Pipeline 成功跑通一次（代码 push → 自动构建镜像 → 部署到 K8s）
- [ ] 6. 配置一条告警规则，故意触发它，在 Prometheus UI 的 Alerts 页面看到 FIRING 状态
- [ ] 7. 能回答：`rate()` 和 `irate()` 的区别？
- [ ] 8. 能回答：Prometheus 是怎么发现要采集哪些 target 的？（ServiceMonitor → Prometheus Operator → Prometheus scrape config）
- [ ] 9. 搭好 Loki + Promtail，在 Grafana Explore 中用 LogQL 查到 demo-app 的日志
- [ ] 10. 能回答：Metrics 和 Logs 的区别？Prometheus vs Loki 各自解决什么问题？

---

## 调试锦囊

### 问题 1：Pod 一直 Pending

```bash
kubectl describe pod <pod-name> -n <namespace> | tail -20
# 看 Events 部分：
#   - "0/2 nodes are available" → 资源不够
#   - "persistentvolumeclaim not found" → PVC 没创建好
```

### 问题 2：镜像拉不下来

```bash
kubectl describe pod <pod-name> -n <namespace> | grep -i "pull\|image\|error"
# 常见原因：
#   - exec format error → ARM64 不兼容，需要 arm64 镜像
#   - ImagePullBackOff → 镜像名写错了或没登录 registry
```

### 问题 3：Grafana 登录不了

```bash
# 查看密码
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

### 问题 4：Prometheus 没有采集到指标

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# 浏览器打开 http://localhost:9090 → Status → Targets
# 红色的就是采集失败的 target
```

### 问题 5：`helm install --wait` 一直卡住不返回

**症状**：执行 `helm upgrade --install ... --wait` 后终端没有任何输出，一直挂住。

**根因分析**：`--wait` 会等所有工作负载 Ready。如果某个 Pod 卡在 `ImagePullBackOff`、`Pending`、`CrashLoopBackOff`，Helm 永远不会返回。

**排查步骤**：
```bash
# 另开终端
ssh k8s-master-01

# 1. 看哪个 Pod 不正常
kubectl get pods -n <namespace>

# 2. 看不正常的 Pod 的 Events
kubectl describe pod <pod-name> -n <namespace> | tail -30

# 3. 常见 Event 解读：
#    ImagePullBackOff → 镜像拉不下来（网络/镜像名/架构问题）
#    0/2 nodes are available → 资源不足
#    FailedMount → PVC 没绑定或存储类问题
```

**OrbStack 特有坑：K8s 节点 VM 访问 Docker Hub 超时/证书错误**

OrbStack 的 K8s 节点是独立 VM，网络环境可能和宿主机不同。在国内网络下，节点 VM 访问 Docker Hub 可能遇到 DNS 污染（返回 Facebook 证书）或 TLS 握手超时。

**快速确认是否网络问题**：
```bash
ssh k8s-master-01
# 测试 Docker Hub 连通性
curl -m 10 -s -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/
# 返回 000 或证书错误 → 网络不通
# 返回 401 → 网络通，只是没认证（正常的）
```

**解决 A：从宿主机搬镜像（单次救急）**
```bash
# Mac 宿主机上
docker pull <镜像名> --platform linux/arm64
docker save <镜像名> -o /tmp/image.tar
scp /tmp/image.tar k8s-master-01:/tmp/
scp /tmp/image.tar k8s-worker-01:/tmp/

# K8s 节点上（每个节点都要）
ssh k8s-master-01 "sudo ctr -n k8s.io image import /tmp/image.tar"
ssh k8s-worker-01 "sudo ctr -n k8s.io image import /tmp/image.tar"

# 重建 Pod
kubectl delete pod -n <namespace> -l <label>
```

**解决 B：配置 containerd 镜像加速器（长期方案）**

参见 Step 2 中的"永久方案"。

### 问题 6：`ctr image import` 报 permission denied

```bash
# ctr 需要 sudo，且命名空间必须是 k8s.io（K8s 使用的 containerd namespace）
sudo ctr -n k8s.io image import /tmp/image.tar

# 验证导入成功
sudo crictl images | grep <镜像名>
```

---

## 补充实战：omniai 项目生产化改造

> 真实项目：`~/work/golang/src/omniai` — AI 创作资产管理平台
> 技术栈：Gin + GORM + MySQL + zerolog + cloudwego/eino

### 项目特点

- **4 个微服务**：web（主力）、admin、engine、worker
- **YAML 配置**：`-configPath` flag 加载，非环境变量模式
- **已有优雅退出**：`signal.NotifyContext` + `server.Shutdown`
- **MySQL 强依赖**：20+ 张表（asset_* + 关联表），migration SQL 575 行
- **deploy 目录原本是空壳**，只有 .gitkeep

### 新增文件结构

```
omniai/
├── Makefile                          # 新增：多服务构建
├── .dockerignore                     # 新增
├── deploy/
│   ├── docker/
│   │   └── Dockerfile.web            # 新增：Ubuntu 24.04, COPY 配置+迁移
│   ├── k8s/
│   │   └── web/
│   │       ├── namespace.yaml
│   │       ├── configmap.yaml        # 应用配置（DB 指向 K8s 服务名）
│   │       ├── migrate-configmap.yaml # 数据库迁移 SQL
│   │       ├── deployment.yaml       # initContainer 迁移 + 探针
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       └── secret.yaml           # DB 密码（模板）
│   └── scripts/
│       └── deploy.sh                 # 新增：一键部署
└── dist/                             # 构建产物（gitignore）
```

### 关键设计决策

1. **配置策略**：项目用 YAML 文件配置，K8s 下通过 ConfigMap 挂载覆盖。DB host 从 `127.0.0.1` 改为 `mysql-primary.mysql`（K8s 服务名）。

2. **数据库迁移**：使用 `mysql:8.0` 镜像作为 InitContainer，从 ConfigMap 挂载 `up.sql` 执行。这样首次部署即自动建表。

3. **Makefile 多服务**：`make build-web / build-admin / build-engine / build-worker`，支持独立编译。

4. **Dockerfile 分层**：二进制 + 配置 + migration 都 COPY 进镜像，K8s 下通过 volume mount 覆盖配置。

### 一行命令复制到项目

```bash
cp -r /Users/liuqianli/Documents/Obsidian/OutBack/omniai-deploy/{Makefile,.dockerignore,deploy} ~/work/golang/src/omniai/
mkdir -p ~/work/golang/src/omniai/dist
```

### 部署到你的 K8s 集群

```bash
cd ~/work/golang/src/omniai

# 1. 编译
make build-web

# 2. 构建镜像
docker build -t omniai-web:latest -f deploy/docker/Dockerfile.web .

# 3. 推送到你的 registry 并更新 deployment.yaml 中的 image 字段

# 4. 一键部署
bash deploy/scripts/deploy.sh

# 5. 验证
kubectl port-forward -n omniai svc/omniai-web-svc 8080:80
curl http://localhost:8080/health
```

> 待办：你集群的 MySQL 需要先创建 `omniai` 数据库（`deploy.sh` 会自动尝试创建），确认 MySQL 密码后更新 Secret。

---

> 这份笔记从零开始一步步带你搭完 CI/CD + 监控体系。预计总耗时 **10-15 小时**（分散到一周）。有卡住的地方随时问我。
