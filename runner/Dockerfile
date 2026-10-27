FROM python:3.12-slim

WORKDIR /app
COPY runner.py .

ENV RUNNER_IN_CONTAINER=1 \
    RUNNER_STATE_DIR=/data \
    PYTHONUNBUFFERED=1

VOLUME /data
EXPOSE 8765

HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8765/health')"

CMD ["python", "runner.py"]
