# 阶段1：基础信息采集
FROM quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.30.0 AS base
USER root
RUN mkdir -p /tmp/build-info && \
    which nginx > /tmp/build-info/nginx-path.txt && \
    nginx -v 2>&1 > /tmp/build-info/nginx-version.txt && \
    echo "/etc/nginx/nginx.conf" > /tmp/build-info/nginx-conf-path.txt && \
    echo "/usr/lib/nginx/modules" > /tmp/build-info/nginx-modules-path.txt && \
    id -u > /tmp/build-info/original-user-id.txt && \
    id -g > /tmp/build-info/original-group-id.txt && \
    mkdir -p /usr/lib/nginx/modules && \
    chmod -R 755 /usr/lib/nginx
USER 101

# 阶段2：编译环境准备
FROM debian:bullseye-slim AS build-env
RUN sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list && \
    apt-get update -o Acquire::Retries=5 && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential \
        wget \
        libpcre3-dev \
        zlib1g-dev \
        libssl-dev \
        libxslt1-dev \
        libgd-dev \
        libgeoip-dev \
    && rm -rf /var/lib/apt/lists/*

# 阶段3：Nginx源码下载
FROM build-env AS source
WORKDIR /build
RUN wget --retry-connrefused --waitretry=10 --tries=5 \
    -O nginx.tar.gz https://nginx.org/download/nginx-1.28.0.tar.gz && \
    tar -zxf nginx.tar.gz && \
    [ -d "nginx-1.28.0" ] || { echo "源码解压失败"; exit 1; }

# 阶段4：Nginx编译构建（关键修复）
FROM build-env AS builder
COPY --from=source /build/nginx-1.28.0 /build/nginx-1.28.0
WORKDIR /build/nginx-1.28.0

# 修复：添加缺失的依赖库
RUN ldconfig && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-ld-opt="-Wl,-rpath,/usr/local/lib" \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-compat \
        --with-threads \
        --with-pcre-jit && \
    make -j$(nproc) && \
    make install && \
    ldd /usr/sbin/nginx > /tmp/nginx-dependencies.txt && \
    /usr/sbin/nginx -v 2>&1 | grep -oE 'nginx/[0-9.]+' | cut -d/ -f2 > /tmp/nginx-build-version.txt

# 阶段5：最终镜像组装（关键修复）
FROM base
USER root

# 复制所有依赖文件
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/lib/nginx /usr/lib/nginx
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /tmp/nginx-dependencies.txt /tmp/
COPY --from=builder /tmp/nginx-build-version.txt /tmp/

# 修复：确保动态链接库可用
RUN set -ex && \
    mkdir -p /var/cache/nginx && \
    mkdir -p /var/log/nginx && \
    chown -R 101:101 /var/cache/nginx /var/log/nginx && \
    ldconfig && \
    # 验证执行能力
    if ! /usr/sbin/nginx -v > /dev/null 2>&1; then \
      echo "Nginx执行失败，依赖信息："; \
      cat /tmp/nginx-dependencies.txt; \
      exit 1; \
    fi && \
    # 版本验证
    NGINX_VERSION=$(/usr/sbin/nginx -v 2>&1 | grep -oE 'nginx/[0-9.]+' | cut -d/ -f2) && \
    [ "$NGINX_VERSION" = "1.28.0" ] || { \
      echo "版本验证失败: $NGINX_VERSION"; \
      echo "编译版本: $(cat /tmp/nginx-build-version.txt)"; \
      echo "依赖检查:"; \
      ldd /usr/sbin/nginx; \
      exit 1; \
    } && \
    # 创建符号链接
    rm -f /usr/bin/nginx && \
    ln -s /usr/sbin/nginx /usr/bin/nginx && \
    echo "Nginx 1.28.0 升级成功" && \
    rm -rf /tmp/build-info

USER 101
HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 \
    CMD [ -e /var/run/nginx.pid ] || exit 1
CMD ["nginx-ingress-controller"]
