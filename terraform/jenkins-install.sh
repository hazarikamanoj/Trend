#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Base packages
apt-get update -y
apt-get install -y openjdk-17-jdk docker.io unzip curl git

# Jenkins
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  -o /usr/share/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# kubectl
curl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

# Let Jenkins run Docker
usermod -aG docker jenkins
systemctl enable --now docker
systemctl enable --now jenkins
systemctl restart jenkins