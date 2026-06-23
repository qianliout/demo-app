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
