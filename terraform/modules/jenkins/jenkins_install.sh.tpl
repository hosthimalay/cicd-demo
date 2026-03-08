#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# jenkins_install.sh.tpl
# Runs automatically on first EC2 boot via user_data.
# Installs all tools Jenkins needs. Takes about 5-8 minutes.
# Check progress: sudo tail -f /var/log/user-data.log
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail
exec > /var/log/user-data.log 2>&1  # Log all output for debugging

echo "=== CI/CD Demo — Jenkins Install Started at $(date) ==="

# ── Update system ─────────────────────────────────────────────────────────────
apt-get update -y
apt-get upgrade -y

# ── Install Java 17 (Jenkins requires this) ───────────────────────────────────
echo "=== Installing Java 17 ==="
apt-get install -y fontconfig openjdk-17-jre
java -version

# ── Install Jenkins ───────────────────────────────────────────────────────────
echo "=== Installing Jenkins ==="
wget -O /usr/share/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

apt-get update -y
apt-get install -y jenkins

systemctl start jenkins
systemctl enable jenkins
echo "=== Jenkins installed and started ==="

# ── Install Docker ────────────────────────────────────────────────────────────
echo "=== Installing Docker ==="
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Allow jenkins user to run Docker without sudo
usermod -aG docker jenkins
echo "=== Docker installed ==="

# ── Install AWS CLI v2 ────────────────────────────────────────────────────────
echo "=== Installing AWS CLI ==="
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
aws --version

# ── Install kubectl ───────────────────────────────────────────────────────────
echo "=== Installing kubectl ==="
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client

# ── Install Helm ──────────────────────────────────────────────────────────────
echo "=== Installing Helm ==="
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# ── Install Python 3 and boto3 ────────────────────────────────────────────────
echo "=== Installing Python and boto3 ==="
apt-get install -y python3 python3-pip
pip3 install boto3 --break-system-packages 2>/dev/null || pip3 install boto3
python3 --version

# ── Install Trivy (container CVE scanner) ────────────────────────────────────
echo "=== Installing Trivy ==="
apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | apt-key add -
echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
  | tee /etc/apt/sources.list.d/trivy.list
apt-get update -y
apt-get install -y trivy
trivy --version

# ── Configure AWS region for all users ───────────────────────────────────────
echo "=== Configuring AWS region ==="
mkdir -p /home/ubuntu/.aws /root/.aws /var/lib/jenkins/.aws

cat > /home/ubuntu/.aws/config << EOF
[default]
region = ${aws_region}
output = json
EOF

cp /home/ubuntu/.aws/config /root/.aws/config
cp /home/ubuntu/.aws/config /var/lib/jenkins/.aws/config
chown -R jenkins:jenkins /var/lib/jenkins/.aws

# ── Configure kubectl for EKS (runs as background job — EKS may not exist yet) ──
# This configures kubectl when EKS is available
# The jenkins user will also need this — done via Jenkins pipeline or manually
cat > /usr/local/bin/configure-eks.sh << 'EKSSCRIPT'
#!/bin/bash
# Run this script after EKS cluster is created:
# sudo /usr/local/bin/configure-eks.sh
AWS_REGION="${aws_region}"
CLUSTER_NAME="${cluster_name}"
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
cp -r /root/.kube /var/lib/jenkins/.kube 2>/dev/null || true
chown -R jenkins:jenkins /var/lib/jenkins/.kube 2>/dev/null || true
echo "kubectl configured for cluster: $CLUSTER_NAME"
EKSSCRIPT
chmod +x /usr/local/bin/configure-eks.sh

# ── Restart Jenkins so Docker group membership takes effect ──────────────────
echo "=== Restarting Jenkins ==="
systemctl restart jenkins

# ── Write a marker file so you can verify install completed ──────────────────
echo "=== Install completed at $(date) ===" > /var/log/jenkins-install-complete.txt
echo "Jenkins URL: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo "Initial admin password location: /var/lib/jenkins/secrets/initialAdminPassword"
echo "=== All done ==="
