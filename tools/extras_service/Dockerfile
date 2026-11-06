# platforms: linux/amd64, linux/arm64
FROM python:3.13-slim@sha256:09a17cad02668ae61ece136b4fd36ac3849e14f670ebedb637ea3e15580525bc
WORKDIR /app
COPY service.py registry.json /app/
RUN useradd --uid 10001 --create-home extras && mkdir /data && chown extras /data
USER extras
EXPOSE 8792
ENTRYPOINT ["python", "/app/service.py", "--host", "0.0.0.0", "--registry", "/app/registry.json", "--database", "/data/cache.sqlite3"]
