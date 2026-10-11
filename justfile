set ignore-comments := true
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

import ".just/linux.just"
import ".just/windows.just"

# Executes all recipes required to serve ignition files
[group('Build & Provisioning')]
run: clean lint build validate serve
  #!/usr/bin/env bash

  set -euo pipefail

  # Ensure environment is cleaned up after serving ignition files.
  trap 'just clean' EXIT


# Updates submodules to latest
[group('Maintenance & Utility')]
update:
  @git submodule update --remote .just/shared
