#!/bin/bash
# Docker + Buildx + Compose on Amazon Linux 2023.
#
# Why this shape:
#   AL2023's `docker` package works fine, but ships no current buildx/compose
#   plugin — and Compose needs buildx >=0.17.0 to build the Flask SAML SP's
#   local Dockerfile ("compose build requires buildx 0.17.0 or later").
#
#   The critical detail is the PLUGIN DIRECTORY. AL2023's docker package looks
#   in /usr/libexec/docker/cli-plugins. Docker CE looks in
#   /usr/local/lib/docker/cli-plugins. Dropping plugins into the CE path while
#   running the AL2023 package means they are silently never found.
#
#   Installing Docker CE instead is possible but messier: Docker publishes no
#   AL2023 repo, so you end up pointing dnf at the CentOS repo and pinning
#   $releasever by hand (it otherwise expands to AL2023's own version string
#   and 404s). Distro package + correct plugin path is simpler and stays
#   supported.

set -e

BUILDX_VERSION="v0.17.0"

echo "Starting Docker, Buildx (${BUILDX_VERSION}+), and Compose setup on Amazon Linux 2023..."

# 1. Update system packages
echo "Updating package lists..."
sudo dnf update -y

# 2. Install Docker Engine from AL2023 repositories
echo "Installing Docker Engine..."
sudo dnf install -y docker

# 3. Create the plugin directory the AL2023 docker package actually reads
echo "Creating Docker CLI plugin directory..."
sudo mkdir -p /usr/libexec/docker/cli-plugins

# 4. Buildx — release assets use amd64/arm64 naming, not uname's x86_64/aarch64
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  BUILDX_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
  BUILDX_ARCH="arm64"
else
  BUILDX_ARCH="$ARCH"
fi

echo "Downloading Buildx binary (${BUILDX_VERSION}) for ${BUILDX_ARCH}..."
sudo curl -SL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}" \
  -o /usr/libexec/docker/cli-plugins/docker-buildx

# 5. Compose — these release assets DO use uname's naming, so no mapping here
echo "Installing Docker Compose plugin..."
sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
  -o /usr/libexec/docker/cli-plugins/docker-compose

# 6. Make both executable
sudo chmod +x /usr/libexec/docker/cli-plugins/docker-buildx
sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# 7. Start and enable the service
echo "Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# 8. Let ec2-user run docker without sudo
echo "Adding user '$USER' to the docker group..."
sudo usermod -aG docker "$USER"

echo "Setup completed successfully."
echo "-------------------------------------------------------"
echo "Verification:"
docker --version
docker buildx version
docker compose version
echo "-------------------------------------------------------"
echo "CRITICAL: log out and back in (new SSH session) for the docker"
echo "group to take effect. Until then every docker command needs sudo."
