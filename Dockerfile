# 基础镜像：使用官方 nginx-ingress-controller 0.30.0
FROM quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.30.0 AS base

# 构建阶段：编译 Nginx 1.28.0
FROM registry.cn-hangzhou.aliyuncs.com/library/debian:bullseye-slim AS builder

# 安装编译依赖（修复语法错误）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    wget \
    libpcre3-dev \
    libz-dev \
    libssl-dev \
    libxslt1-dev \
    libgd-dev \
    libgeoip-dev \
    && rm -rf /var/lib/apt/lists/*

# 下载并编译 Nginx 1.28.0
WORKDIR /build
RUN wget -O nginx.tar.gz https://nginx.org/download/nginx-1.28.0.tar.gz && \
    tar -zxf nginx.tar.gz && \
    cd nginx-1.28.0 && \
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
    make install

# 最终镜像：替换原 Nginx 二进制文件
FROM base

# 复制编译好的 Nginx 1.28.0
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/lib/nginx /usr/lib/nginx

# 验证版本
RUN nginx -v

# 保留原控制器启动命令
CMD ["nginx-ingress-controller"]
