#!/bin/bash
set -e

# Ensure standard binary paths are available to root
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin

# Logging for debugging (viewable at /var/log/user-data.log)
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "=== Starting S3 Artifact Boot Script ==="

# Variables injected during deployment
S3_JAR_PATH="__S3_JAR_PATH__"
DEPLOY_SHA="__DEPLOY_SHA__"
APP_DIR="/home/ssm-user/spring-boot-docker-rest-api/rest-api/target"
JAR_NAME="spring-boot-rest-api-v1.jar"

echo "Deploying commit: ${DEPLOY_SHA}"
echo "Downloading JAR from: ${S3_JAR_PATH}"

# Ensure destination directory exists
mkdir -p "${APP_DIR}"

# Stop old service if running (releases file lock and frees RAM on t3.micro)
systemctl stop springboot || true

# Download the pre-built JAR from private S3 bucket with retry (up to 5 attempts)
DOWNLOAD_SUCCESS=false
for i in {1..5}; do
  if aws s3 cp "${S3_JAR_PATH}" "${APP_DIR}/${JAR_NAME}" --region ap-south-1; then
    echo "JAR downloaded successfully on attempt $i."
    DOWNLOAD_SUCCESS=true
    break
  fi
  echo "Download attempt $i failed. Retrying in 3 seconds..."
  sleep 3
done

if [ "$DOWNLOAD_SUCCESS" != "true" ]; then
  echo "ERROR: Failed to download JAR from S3 after 5 attempts."
  exit 1
fi

# Ensure proper permissions
chown -R ssm-user:ssm-user "${APP_DIR}"
chmod 755 "${APP_DIR}/${JAR_NAME}"

# Reload systemd and start the springboot service
echo "Starting springboot service..."
systemctl daemon-reload
systemctl restart springboot

# Wait for Spring Boot application to become locally healthy (up to 60s)
echo "Waiting for Spring Boot to start on port 9090..."
APP_HEALTHY=false
for attempt in {1..20}; do
  if curl -s -f http://localhost:9090/api/v1/categories/ > /dev/null 2>&1; then
    echo "Application is healthy and responding on port 9090!"
    APP_HEALTHY=true
    break
  fi
  echo "Health check attempt $attempt/20. Waiting 3s..."
  sleep 3
done

if [ "$APP_HEALTHY" != "true" ]; then
  echo "WARNING: Application did not respond within 60s. Inspecting service status:"
  systemctl status springboot --no-pager || true
  journalctl -u springboot -n 50 --no-pager || true
  exit 1
fi

echo "=== Boot Script Completed Successfully ==="
