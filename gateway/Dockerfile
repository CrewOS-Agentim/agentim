FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY agentim ./agentim
COPY config ./config
COPY skills ./skills

ENV PYTHONUNBUFFERED=1 AGENTIM_DATA_DIR=/data
VOLUME /data
EXPOSE 8780

HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8780/health')"

CMD ["python", "-m", "agentim"]
