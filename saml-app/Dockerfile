FROM python:3.12-slim

# xmlsec1 is required by python3-saml for XML signature verification.
# Without it, install succeeds but every assertion validation fails at runtime.
RUN apt-get update && \
    apt-get install -y --no-install-recommends xmlsec1 pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

RUN useradd --create-home appuser
USER appuser

# --preload imports app:app ONCE in the master before forking, so all workers
# share one Flask secret_key. Without it, each worker signs cookies with its
# own key and the browser round-robins between them: the classic "I have to
# refresh several times after login" symptom.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--preload", "app:app"]
