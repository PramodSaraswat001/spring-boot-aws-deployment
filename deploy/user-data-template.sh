#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# EC2 Boot Provisioning Script (Base Ubuntu 24.04 LTS AMI)
# ═══════════════════════════════════════════════════════════════════
# Provisions a fresh Ubuntu 24.04 instance into a fully running
# Spring Boot application node.
#
# Placeholders replaced at deploy time by GitHub Actions (sed):
#   __S3_JAR_PATH__  → s3://bucket/releases/<sha>/spring-boot-rest-api-v1.jar
#   __DEPLOY_SHA__   → git commit SHA being deployed
# ═══════════════════════════════════════════════════════════════════

# ─── Environment ───
export PATH=$PATH:/snap/bin:/usr/local/bin:/usr/bin:/bin
export DEBIAN_FRONTEND=noninteractive

# ─── Logging ───
# All output → /var/log/user-data.log + system console + syslog
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
echo "=== EC2 Boot Provisioning Started ==="
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ─── Variables (injected by deploy.yml via sed) ───
S3_JAR_PATH="__S3_JAR_PATH__"
DEPLOY_SHA="__DEPLOY_SHA__"

# ─── Constants ───
APP_USER="springboot"
APP_DIR="/opt/springboot"
JAR_NAME="spring-boot-rest-api-v1.jar"
AWS_REGION="ap-south-1"

echo "Deploying commit: ${DEPLOY_SHA}"
echo "JAR source: ${S3_JAR_PATH}"

# ═══════════════════════════════════════════════════════════════════
# STEP 1: System Updates & Java 8 Installation
# ═══════════════════════════════════════════════════════════════════
echo "── Step 1: Installing Java 8 ──"

# Wait for cloud-init/apt lock if running
for i in {1..30}; do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for apt lock to release (attempt $i/30)..."
  sleep 5
done

apt-get update -y
apt-get install -y openjdk-8-jre-headless curl jq

java -version 2>&1
echo "Java installed successfully."

# ═══════════════════════════════════════════════════════════════════
# STEP 2: Install AWS CLI (via snap)
# ═══════════════════════════════════════════════════════════════════
echo "── Step 2: Installing AWS CLI ──"

if ! command -v aws &> /dev/null; then
  snap install aws-cli --classic
  sleep 5
fi

aws --version
echo "AWS CLI ready."

# ═══════════════════════════════════════════════════════════════════
# STEP 3: Create Dedicated System User & App Directory
# ═══════════════════════════════════════════════════════════════════
echo "── Step 3: Creating application user and directory ──"

if ! id "${APP_USER}" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${APP_USER}"
  echo "Created system user: ${APP_USER}"
else
  echo "User ${APP_USER} already exists."
fi

mkdir -p "${APP_DIR}"
chown "${APP_USER}:${APP_USER}" "${APP_DIR}"

# ═══════════════════════════════════════════════════════════════════
# STEP 4: Download JAR from S3 (with retry)
# ═══════════════════════════════════════════════════════════════════
echo "── Step 4: Downloading JAR from S3 ──"

DOWNLOAD_SUCCESS=false
for i in {1..5}; do
  if aws s3 cp "${S3_JAR_PATH}" "${APP_DIR}/${JAR_NAME}" --region "${AWS_REGION}"; then
    echo "JAR downloaded successfully on attempt $i."
    DOWNLOAD_SUCCESS=true
    break
  fi
  echo "Download attempt $i failed. Retrying in 5 seconds..."
  sleep 5
done

if [ "$DOWNLOAD_SUCCESS" != "true" ]; then
  echo "FATAL: Failed to download JAR from S3 after 5 attempts."
  exit 1
fi

chown "${APP_USER}:${APP_USER}" "${APP_DIR}/${JAR_NAME}"
chmod 644 "${APP_DIR}/${JAR_NAME}"
echo "JAR ready at: ${APP_DIR}/${JAR_NAME}"

# ═══════════════════════════════════════════════════════════════════
# STEP 5: Fetch Configuration from SSM Parameter Store (/springboot/dev/*)
# ═══════════════════════════════════════════════════════════════════
echo "── Step 5: Fetching configuration from SSM Parameter Store ──"

ACTIVE_PROFILE=$(aws ssm get-parameter --name "/springboot/dev/ACTIVE_PROFILE" --with-decryption --region "${AWS_REGION}" --query "Parameter.Value" --output text)
DB_HOST=$(aws ssm get-parameter --name "/springboot/dev/DB_HOST" --with-decryption --region "${AWS_REGION}" --query "Parameter.Value" --output text)
DB_PORT=$(aws ssm get-parameter --name "/springboot/dev/DB_PORT" --with-decryption --region "${AWS_REGION}" --query "Parameter.Value" --output text)
DB_NAME=$(aws ssm get-parameter --name "/springboot/dev/DB_NAME" --with-decryption --region "${AWS_REGION}" --query "Parameter.Value" --output text)
DB_USER=$(aws ssm get-parameter --name "/springboot/dev/DB_USER" --with-decryption --region "${AWS_REGION}" --query "Parameter.Value" --output text)
DB_PASS=$(aws ssm get-parameter --name "/springboot/dev/DB_PASS" --with-decryption --region "${AWS_REGION}" --query "Parameter.Value" --output text)

echo "DB config loaded (host=${DB_HOST}, port=${DB_PORT}, db=${DB_NAME}, profile=${ACTIVE_PROFILE})"

# ═══════════════════════════════════════════════════════════════════
# STEP 6: Create Environment File
# ═══════════════════════════════════════════════════════════════════
echo "── Step 6: Creating environment file ──"

cat > "${APP_DIR}/springboot.env" << ENVFILE
ACTIVE_PROFILE=${ACTIVE_PROFILE}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DEPLOY_SHA=${DEPLOY_SHA}
ENVFILE

chown "${APP_USER}:${APP_USER}" "${APP_DIR}/springboot.env"
chmod 600 "${APP_DIR}/springboot.env"

# ═══════════════════════════════════════════════════════════════════
# STEP 7: Create systemd Service Unit
# ═══════════════════════════════════════════════════════════════════
echo "── Step 7: Creating systemd service unit ──"

cat > /etc/systemd/system/springboot.service << 'UNIT'
[Unit]
Description=Spring Boot REST API Application
Documentation=https://github.com/PramodSaraswat001/spring-boot-aws-deployment
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=springboot
Group=springboot
WorkingDirectory=/opt/springboot

EnvironmentFile=/opt/springboot/springboot.env

# t3.micro safe memory allocation (1 GB total RAM)
ExecStart=/usr/bin/java \
    -Xms128m -Xmx512m \
    -XX:MaxMetaspaceSize=128m \
    -Djava.security.egd=file:/dev/./urandom \
    -jar /opt/springboot/spring-boot-rest-api-v1.jar

Restart=on-failure
RestartSec=10
SuccessExitStatus=143

StandardOutput=journal
StandardError=journal
SyslogIdentifier=springboot

# Security Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/springboot
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

# ═══════════════════════════════════════════════════════════════════
# STEP 8: Enable & Start the Service
# ═══════════════════════════════════════════════════════════════════
echo "── Step 8: Starting springboot service ──"

systemctl daemon-reload
systemctl enable springboot
systemctl start springboot

# ═══════════════════════════════════════════════════════════════════
# STEP 9: Health Check on Port 9090 (wait up to 240s)
# ═══════════════════════════════════════════════════════════════════
echo "── Step 9: Waiting for application health on port 9090 ──"

APP_HEALTHY=false
for attempt in {1..80}; do
  if curl -s -f http://localhost:9090/api/v1/categories/ > /dev/null 2>&1; then
    echo "Application is healthy and responding on port 9090!"
    APP_HEALTHY=true
    break
  fi
  echo "Health check attempt ${attempt}/80. Waiting 3s..."
  sleep 3
done

if [ "$APP_HEALTHY" != "true" ]; then
  echo "FATAL: Application did not respond within 240s."
  systemctl status springboot --no-pager || true
  journalctl -u springboot -n 100 --no-pager || true
  exit 1
fi

echo "=== EC2 Boot Provisioning Completed Successfully ==="
