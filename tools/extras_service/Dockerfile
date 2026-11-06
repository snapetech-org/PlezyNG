FROM python:3.13-slim
WORKDIR /app
COPY service.py registry.json /app/
RUN useradd --uid 10001 --create-home extras && mkdir /data && chown extras /data
USER extras
EXPOSE 8792
ENTRYPOINT ["python", "/app/service.py", "--host", "0.0.0.0", "--registry", "/app/registry.json", "--database", "/data/cache.sqlite3"]
