FROM python:3.11 AS builder

ENV PATH="/opt/venv/bin:$PATH"
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libopus-dev \
    && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv

COPY requirements.fargate.txt /tmp/requirements.txt
# Install the frozen dependency set as recorded in the lock file.
RUN pip install --no-cache-dir --upgrade --no-deps -r /tmp/requirements.txt

FROM python:3.11-slim

WORKDIR /app
ENV PATH="/opt/venv/bin:$PATH"

RUN apt-get update && apt-get -y install \
    curl \
    ffmpeg \
    libasound2 \
    libogg0 \
    libopus0 \
    libpulse0 \
    libsndfile1 \
    unzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
COPY . .

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
