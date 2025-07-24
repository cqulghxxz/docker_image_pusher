# 基础镜像：使用官方 nginx-ingress-controller 0.30.0
FROM quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.30.0 AS base

# 构建阶段：编译 Nginx 1.28.0
FROM debian:bullseye-slim AS builder

# 安装编译依赖（确保所有命令以 RUN 开头）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \      # 确保 HTTPS 证书验证正常
    build-essential \      # 包含 gcc、make 等基础编译工具
    wget \                 # 下载源码
    libpcre3-dev \         # PCRE 正则表达式支持
    zlib1g-dev \           # 压缩模块支持
    libssl-dev \           # SSL/TLS 模块支持
    libxslt1-dev \         # XSLT 模块支持
    libgd-dev \            # 图像过滤模块支持
    libgeoip-dev \         # GeoIP 模块支持
    && rm -rf /var/lib/apt/lists/*  # 清理缓存以减小镜像体积

# 下载并编译 Nginx 1.28.0（保持与原控制器兼容的模块）
WORKDIR /build
RUN wget -O nginx.tar.gz https://nginx.org/download/nginx-1.28.0.tar.gz && \
    tar -zxf nginx.tar.gz && \
    cd nginx-1.28.0 && \
    # 配置编译参数
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
    make -j$(nproc) && \  # 多线程编译，加速构建
    make install

# 最终镜像：替换原 Nginx 二进制文件
FROM base

# 复制编译好的 Nginx 1.28.0 到目标路径（覆盖原文件）
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/lib/nginx /usr/lib/nginx

# 验证版本（构建时会执行，失败则构建中断）
RUN nginx -v

# 保留原控制器的启动命令
CMD ["nginx-ingress-controller"]
