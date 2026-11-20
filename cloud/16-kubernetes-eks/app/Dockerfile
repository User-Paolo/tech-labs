# checkov:skip=CKV_DOCKER_2:Kubernetes ignores HEALTHCHECK and uses its own probes
# The libraries are plain Python, so they're installed on the build machine and only copied into the image
FROM --platform=$BUILDPLATFORM python:3.13-alpine AS deps
COPY requirements.txt .
# Stops the build if a library ever brings compiled code built for the wrong CPU
RUN pip install --no-cache-dir --target /deps -r requirements.txt && ! find /deps -name '*.so' | grep .

FROM python:3.13-alpine
WORKDIR /app
COPY --from=deps /deps /usr/local/lib/python3.13/site-packages
COPY app.py .
USER 65534
EXPOSE 8080
CMD ["python", "-u", "app.py"]
