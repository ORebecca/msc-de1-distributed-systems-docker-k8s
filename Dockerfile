# Small, official Python base image. Alpine (musl-based) is used instead
# of the Debian slim variant to minimize the OS package surface and the
# resulting number of OS-level CVEs (see security/vulnerability-scan.txt).
FROM python:3.12-alpine

# Clear working directory for the application
WORKDIR /app

# Copy dependency file first so this layer is cached
# unless requirements.txt actually changes
COPY requirements.txt .

# Install only what the application needs, no pip cache left behind.
# pip/setuptools/wheel are build-time tools only (not used at runtime by
# the Flask app), so they are removed afterwards to shrink the image and
# drop their own reported vulnerabilities from the final scan.
RUN pip install --no-cache-dir -r requirements.txt \
    && pip uninstall -y pip setuptools wheel \
    && find /usr/local/lib/python3.12 -name "__pycache__" -exec rm -rf {} +

# Copy only the files required at runtime
COPY app/ ./app/
COPY run.py .

# Create a dedicated non-root user/group to run the app
RUN addgroup -S appgroup \
    && adduser -S -G appgroup -H -s /sbin/nologin appuser \
    && chown -R appuser:appgroup /app

USER appuser

# Only the port the Flask app actually listens on
EXPOSE 5000

# Docker-level health check against the root route
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:5000/').status == 200 else sys.exit(1)"

# Exec form so the process receives signals directly (proper SIGTERM handling)
CMD ["python", "run.py"]
