#!/usr/bin/env bash
set -e

echo ">>> Checking if Docker is installed..."
if command -v docker &> /dev/null; then
    echo ">>> Docker detected. Wiping all containers, images, volumes, and networks..."

    # Stop Docker service
    sudo systemctl stop docker || true

    # Remove all containers
    sudo docker ps -aq | xargs -r sudo docker rm -fv

    # Remove all images
    sudo docker images -q | xargs -r sudo docker rmi -f

    # Remove all volumes
    sudo docker volume ls -q | xargs -r sudo docker volume rm -f

    # Remove all custom networks
    sudo docker network ls --filter "type=custom" -q | xargs -r sudo docker network rm

    echo ">>> Uninstalling Docker packages..."
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    sudo apt-get autoremove -y --purge
    sudo apt-get clean

    echo ">>> Removing leftover Docker files..."
    sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker ~/.docker
else
    echo ">>> Docker is not installed. Proceeding with fresh install."
fi

echo ">>> Installing Docker from official repo..."

# Update system
sudo apt-get update

# Install required packages
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker’s official GPG key
sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up the stable repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update and install Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo ">>> Starting and enabling Docker..."
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group
if groups $USER | grep -q '\bdocker\b'; then
    echo ">>> User $USER is already in docker group."
else
    echo ">>> Adding $USER to docker group..."
    sudo usermod -aG docker $USER
    echo ">>> You may need to log out and back in for group changes to take effect."
fi

echo ">>> Docker installation complete!"
docker --version
