# platforms: linux/amd64, linux/arm64
FROM python:3.13.18-slim-trixie@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90
WORKDIR /app
COPY service.py registry.json /app/
RUN apt-get update \
    && apt-get full-upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
        /usr/local/lib/python3.13/ensurepip \
        /usr/local/lib/python3.13/site-packages/pip \
        /usr/local/lib/python3.13/site-packages/pip-*.dist-info \
        /usr/local/lib/python3.13/site-packages/setuptools \
        /usr/local/lib/python3.13/site-packages/setuptools-*.dist-info \
        /usr/local/lib/python3.13/site-packages/pkg_resources \
        /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.13
RUN useradd --uid 10001 --create-home extras && mkdir /data && chown extras /data
USER extras
EXPOSE 8792
ENTRYPOINT ["python", "/app/service.py", "--host", "0.0.0.0", "--registry", "/app/registry.json", "--database", "/data/cache.sqlite3"]
