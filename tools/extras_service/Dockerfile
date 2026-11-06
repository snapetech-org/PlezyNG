FROM python:3.13-slim
WORKDIR /app
COPY service.py /app/service.py
RUN useradd --uid 10001 --create-home extras && mkdir /data && chown extras /data
USER extras
EXPOSE 8792
ENTRYPOINT ["python", "/app/service.py", "--host", "0.0.0.0", "--registry", "/data/registry.json", "--database", "/data/cache.sqlite3"]
