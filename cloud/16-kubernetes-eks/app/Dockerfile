# checkov:skip=CKV_DOCKER_2:Kubernetes ignores HEALTHCHECK and uses its own probes
FROM python:3.13-alpine
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
USER 65534
EXPOSE 8080
CMD ["python", "-u", "app.py"]
