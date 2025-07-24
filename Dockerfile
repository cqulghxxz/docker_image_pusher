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

# 阶段2：编译环境准备（使用国内多镜像源轮询）
FROM debian:bullseye-slim AS build-env
RUN set -e; \
    for mirror in mirrors.tuna.tsinghua.edu.cn mirrors.huaweicloud.com mirrors.aliyun.com; do \
      echo "尝试使用镜像源: $mirror"; \
      sed -i "s|deb.debian.org|$mirror|g" /etc/apt/sources.list; \
      sed -i "s|security.debian.org|$mirror|g" /etc/apt/sources.list; \
      if apt-get update -o Acquire::Retries=3; then \
        if apt-get install -y --no-install-recommends \
            ca-certificates \
            build-essential \
            wget \
            libpcre3-dev \
            zlib1g-dev \
            libssl-dev \
            libxslt1-dev \
            libgd-dev \
            libgeoip-dev; then \
          rm -rf /var/lib/apt/lists/*; \
          break; \
        fi; \
      fi; \
      echo "镜像源 $mirror 失败，尝试下一个..."; \
      sleep 3; \
    done

# 阶段3：Nginx源码下载（多CDN源重试）
FROM build-env AS source
WORKDIR /build
RUN set -e; \
    for url in \
      "https://nginx.org/download/nginx-1.28.0.tar.gz" \
      "https://mirrors.tencent.com/nginx/nginx-1.28.0.tar.gz" \
      "https://mirrors.tuna.tsinghua.edu.cn/nginx/nginx-1.28.0.tar.gz"; \
    do \
      echo "尝试从 $url 下载"; \
      if wget --retry-connrefused --waitretry=10 --tries=3 -O nginx.tar.gz "$url"; then \
        tar -zxf nginx.tar.gz && \
        if [ -d "nginx-1.28.0" ]; then break; fi; \
      fi; \
      echo "下载失败，尝试备用源..."; \
      rm -f nginx.tar.gz; \
    done && \
    [ -d "nginx-1.28.0" ] || { echo "所有源码下载源均失败"; exit 1; }

# 阶段4：Nginx编译构建
FROM build-env AS builder
COPY --from=source /build/nginx-1.28.0 /build/nginx-1.28.0
WORKDIR /build/nginx-1.28.0
RUN ./configure \
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
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-http_slice_module \
        --with-compat \
        --with-pcre-jit && \
    make -j$(nproc) && \
    make install && \
    /usr/sbin/nginx -v 2>&1 | grep -oE 'nginx/[0-9.]+' | cut -d/ -f2 > /tmp/nginx-build-version.txt

# 阶段5：最终镜像组装
FROM base
USER root

# 直接覆盖安装
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/lib/nginx /usr/lib/nginx

# 版本验证
RUN set -ex; \
    rm -f /usr/bin/nginx; \
    ln -s /usr/sbin/nginx /usr/bin/nginx; \
    NGINX_VERSION=$(/usr/sbin/nginx -v 2>&1 | grep -oE 'nginx/[0-9.]+' | cut -d/ -f2); \
    [ "$NGINX_VERSION" = "1.28.0" ] || { \
      echo "版本验证失败: $NGINX_VERSION"; \
      echo "编译版本: $(cat /tmp/nginx-build-version.txt 2>/dev/null || echo '未知')"; \
      exit 1; \
    }; \
    echo "Nginx 1.28.0 升级成功"; \
    rm -rf /tmp/build-info

USER 101
HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 \
    CMD [ -e /var/run/nginx.pid ] || exit 1
CMD ["nginx-ingress-controller"]
