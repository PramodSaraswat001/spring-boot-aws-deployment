#!/bin/bash
set -e

# Ensure standard binary and snap paths are available to root
export PATH=$PATH:/snap/bin:/usr/local/bin:/usr/bin:/bin

# Logging for debugging (viewable at /var/log/user-data.log)
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "=== Starting S3 Artifact Boot Script ==="

# 0. Immediately kill the stale auto-started service from the AMI
#    The AMI has springboot.service enabled, so systemd auto-starts it on boot
#    BEFORE user-data runs. This old/stale JAR wastes RAM and holds file locks.
echo "Stopping stale springboot service (if auto-started by AMI)..."
systemctl stop springboot 2>/dev/null || true
systemctl disable springboot 2>/dev/null || true
echo "Stale service stopped and disabled."

# 1. Ensure AWS CLI is installed (Ubuntu 24.04 uses snap)
if ! command -v aws &> /dev/null; then
  echo "AWS CLI not found. Installing via snap..."
  snap install aws-cli --classic
fi
echo "Using AWS CLI version:"
aws --version

# 2. Variables injected during deployment
S3_JAR_PATH="__S3_JAR_PATH__"
DEPLOY_SHA="__DEPLOY_SHA__"
APP_DIR="/home/ssm-user/spring-boot-docker-rest-api/rest-api/target"
JAR_NAME="spring-boot-rest-api-v1.jar"

echo "Deploying commit: ${DEPLOY_SHA}"
echo "Downloading JAR from: ${S3_JAR_PATH}"

# Ensure destination directory exists
mkdir -p "${APP_DIR}"

# (Service already stopped in step 0 above)

# 3. Download the pre-built JAR from private S3 bucket with retry (up to 5 attempts)
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

# 4. Ensure proper permissions
chown -R ssm-user:ssm-user "${APP_DIR}"
chmod 755 "${APP_DIR}/${JAR_NAME}"

# 4.5. Apply JVM memory limits via systemd drop-in override
#      t3.micro has only 1 GB RAM. Without limits, the JVM can consume all
#      available memory and get killed by the Linux OOM killer, which causes
#      the springboot service to crash, ALB health check to fail, and ASG
#      to terminate the instance in a loop.
#
#      Memory budget on t3.micro (1024 MB):
#        OS + system services  : ~300 MB
#        JVM heap (-Xmx512m)   : ~512 MB
#        JVM metaspace/threads : ~150 MB
#        Buffer                : ~62 MB
echo "Applying JVM memory limits for t3.micro..."
mkdir -p /etc/systemd/system/springboot.service.d
cat > /etc/systemd/system/springboot.service.d/memory-limits.conf << 'OVERRIDE'
[Service]
ExecStart=
ExecStart=/usr/bin/java -Xms128m -Xmx512m -XX:MaxMetaspaceSize=128m -jar /home/ssm-user/spring-boot-docker-rest-api/rest-api/target/spring-boot-rest-api-v1.jar
OVERRIDE
echo "JVM memory limits applied: -Xms128m -Xmx512m -XX:MaxMetaspaceSize=128m"

# 5. Re-enable, reload, and start the springboot service
echo "Re-enabling and starting springboot service..."
systemctl daemon-reload
systemctl enable springboot
systemctl restart springboot

# 6. Wait for Spring Boot application to become locally healthy (up to 180s)
echo "Waiting for Spring Boot to start on port 9090..."
APP_HEALTHY=false
for attempt in {1..60}; do
  if curl -s -f http://localhost:9090/api/v1/categories/ > /dev/null 2>&1; then
    echo "Application is healthy and responding on port 9090!"
    APP_HEALTHY=true
    break
  fi
  echo "Health check attempt $attempt/60. Waiting 3s..."
  sleep 3
done

if [ "$APP_HEALTHY" != "true" ]; then
  echo "WARNING: Application did not respond within 180s. Inspecting service status:"
  systemctl status springboot --no-pager || true
  journalctl -u springboot -n 50 --no-pager || true
  exit 1
fi

echo "=== Boot Script Completed Successfully ==="
