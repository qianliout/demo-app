FROM scratch

WORKDIR /app

# 复制 make build 产出的静态二进制
COPY bin/demo-app /app/demo-app

# 使用固定非 root UID/GID 运行，避免依赖基础镜像创建用户。
USER 65532:65532

EXPOSE 8080
CMD ["/app/demo-app"]
