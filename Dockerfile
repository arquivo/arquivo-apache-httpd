# Arquivo.pt Apache httpd: the official httpd 2.4 image plus the third-party modules
# Arquivo.pt uses (mod_qos and mod_maxminddb), compiled with apxs on a build stage.
# mod_ssl, mod_proxy_uwsgi and mod_ratelimit are already shipped by the official image.
#
# The base image is pinned by digest, on both stages (Dependabot only updates FROM lines
# and proposes the version/digest bumps).
FROM httpd:2.4.69-trixie@sha256:c842ac797bd1fe8b3cd26d002ac9d948aa2814097544600600b35aef42e6785a AS build

ARG MOD_QOS_VERSION=11.79
ARG MOD_QOS_SHA256=314a60638be42203cd0ed6ed1fe22085c082919545561387db4e7cb35594d755
ARG MOD_MAXMINDDB_VERSION=1.3.0
ARG MOD_MAXMINDDB_SHA256=877d3a36fa4bbcf807468c00b8cfedd7e16fa4039c5d465b5490bbdb243ad5cd

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gcc \
        libapr1-dev \
        libaprutil1-dev \
        libc6-dev \
        libmaxminddb-dev \
        libssl-dev \
        perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# mod_qos only uses the httpd regex API (ap_pregcomp), so it is compiled without the
# -lpcre (PCRE1) of its own Makefile, which no longer exists on Debian trixie.
RUN curl -fsSLo mod_qos.tar.gz "https://downloads.sourceforge.net/project/mod-qos/mod_qos-${MOD_QOS_VERSION}.tar.gz" \
    && echo "${MOD_QOS_SHA256}  mod_qos.tar.gz" | sha256sum -c - \
    && tar xzf mod_qos.tar.gz \
    && cd "mod_qos-${MOD_QOS_VERSION}/apache2" \
    && apxs -c mod_qos.c -lcrypto \
    && install -m 755 .libs/mod_qos.so /build/mod_qos.so

RUN curl -fsSLo mod_maxminddb.tar.gz "https://github.com/maxmind/mod_maxminddb/releases/download/${MOD_MAXMINDDB_VERSION}/mod_maxminddb-${MOD_MAXMINDDB_VERSION}.tar.gz" \
    && echo "${MOD_MAXMINDDB_SHA256}  mod_maxminddb.tar.gz" | sha256sum -c - \
    && tar xzf mod_maxminddb.tar.gz \
    && cd "mod_maxminddb-${MOD_MAXMINDDB_VERSION}/src" \
    && apxs -c mod_maxminddb.c -lmaxminddb \
    && install -m 755 .libs/mod_maxminddb.so /build/mod_maxminddb.so


FROM httpd:2.4.69-trixie@sha256:c842ac797bd1fe8b3cd26d002ac9d948aa2814097544600600b35aef42e6785a

# libmaxminddb0 is required by mod_maxminddb (libcrypto, used by mod_qos, is already present).
# python3-minimal runs the url_escape.py RewriteMap program of the Arquivo.pt configuration.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libmaxminddb0 \
        python3-minimal \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/mod_qos.so /build/mod_maxminddb.so /usr/local/apache2/modules/

# Modules are loaded from conf.modules.d/ (the CentOS layout used by the Arquivo.pt
# configuration), instead of the LoadModule list of the stock httpd.conf, and site
# configuration is read from conf.d/.
COPY conf.modules.d/ /usr/local/apache2/conf.modules.d/
RUN mkdir -p /usr/local/apache2/conf.d \
    && sed -i \
        -e '/^#\?LoadModule /d' \
        -e 's|^Listen 80$|Listen 80\n\nInclude conf.modules.d/*.conf|' \
        /usr/local/apache2/conf/httpd.conf \
    && echo 'IncludeOptional conf.d/*.conf' >> /usr/local/apache2/conf/httpd.conf \
    && httpd -t

HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=10s \
    CMD ["bash", "-c", "echo > /dev/tcp/127.0.0.1/80"]
