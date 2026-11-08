import "shared/output.just"

# Remove all rendered ignition files.
[linux]
[no-cd]
[group('Maintenance & Utility')]
clean:
  #!/usr/bin/env bash
  set -euo pipefail

  # Remove all rendered ignition files in servers/ directories recursively.
  find servers -type f -name "*.ign" -delete

  # Remove all .cache directories in servers/ directories recursively.
  find servers -type d -name ".cache" -exec rm -rf {} +

# Download latest stable Fedora CoreOS ISO
[linux]
[no-cd]
[group('Maintenance & Utility')]
download-iso:
  @podman run --pull always --rm -v .:/data -w /data quay.io/coreos/coreos-installer:release download -f iso

# Configures WSL2 environment for development.
[linux]
[no-cd]
[group('Maintenance & Utility')]
setup:
  #!/usr/bin/env bash

  set -euo pipefail

  if just is-wsl-environment && just is-ubuntu; then
    # Update package cache
    sudo apt update

    # Update existing packages
    sudo apt upgrade -y

    # Install butane package if needed.
    if ! which butane &>/dev/null; then
      curl -sSL https://github.com/coreos/butane/releases/latest/download/butane-x86_64-unknown-linux-gnu -o butane
      sudo mkdir -p /usr/local/bin
      sudo mv butane /usr/local/bin/
      sudo chmod +x /usr/local/bin/butane
    else
      just display-info "Butane is already installed."
    fi

    # Install yamllint package if needed.
    if ! which yamllint &>/dev/null; then
      sudo apt install -y yamllint
    else
      just display-info "YAMLLint is already installed."
    fi

    # Install podman packages if needed.
    if ! which podman &>/dev/null; then
      sudo apt install -y podman podman-docker
    else
      just display-info "Podman is already installed."
    fi

    # Install python packages if needed.
    if ! which python3 &>/dev/null; then
      sudo apt install -y python3 python3-pip
    else
      just display-info "Python is already installed."
    fi
  else
    just display-error "The setup recipe only works for WSL2-based Ubuntu distributions."
    exit 1
  fi

[linux]
[no-cd]
[private]
is-ubuntu:
  #!/usr/bin/env bash

  set -euo pipefail

  if [ -s "/etc/os-release" ]; then
    . /etc/os-release
  fi

  if [[ "$ID" == "ubuntu" || "$NAME" =~ [Uu]buntu ]]; then
    exit 0
  fi

  exit 1

[linux]
[no-cd]
[private]
is-wsl-environment:
  #!/usr/bin/env bash

  set -euo pipefail

  if grep -qi "microsoft" /proc/version 2>/dev/null || \
    grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null; then
    exit 0
  fi

  if [ -n "$WSL_DISTRO_NAME" ]; then
    exit 0
  fi

  exit 1

