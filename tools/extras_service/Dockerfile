# platforms: linux/amd64, linux/arm64
FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
WORKDIR /app
COPY service.py registry.json /app/
RUN apk upgrade --no-cache --available \
    && rm -rf \
        /usr/local/lib/python3.13/ensurepip \
        /usr/local/lib/python3.13/site-packages/pip \
        /usr/local/lib/python3.13/site-packages/pip-*.dist-info \
        /usr/local/lib/python3.13/site-packages/setuptools \
        /usr/local/lib/python3.13/site-packages/setuptools-*.dist-info \
        /usr/local/lib/python3.13/site-packages/pkg_resources \
        /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.13
RUN addgroup -S -g 10001 extras \
    && adduser -S -D -H -u 10001 -G extras extras \
    && mkdir -p /data \
    && chown extras:extras /data
USER extras
EXPOSE 8792
ENTRYPOINT ["python", "/app/service.py", "--host", "0.0.0.0", "--registry", "/app/registry.json", "--database", "/data/cache.sqlite3"]
