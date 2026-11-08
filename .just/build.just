import "shared/output.just"

# Transpiles all configurations across all server profiles sequentially
[linux]
[no-cd]
[group('Build & Provisioning')]
build:
  #!/usr/bin/env bash
  set -euo pipefail

  # Pull the Butane container image to ensure we have the latest version for rendering
  podman pull -q quay.io/coreos/butane:release > /dev/null

  echo "==> Discovering server profiles..."
  mapfile -t PROFILES < <(find servers -mindepth 1 -maxdepth 1 -type d | sort)
  
  # Loop through each profile and build it sequentially
  for PROFILE_DIR in "${PROFILES[@]}"; do
    PROFILE="$(basename "$PROFILE_DIR")"
    just build-profile "$PROFILE"
  done

  echo "==> All profiles built successfully!"

# Builds a single server profile (hooks, fragments, main.bu)
[linux]
[no-cd]
[group('Build & Provisioning')]
build-profile profile:
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{profile}}"
  PROFILE_DIR="servers/${PROFILE}"

  if [ ! -d "$PROFILE_DIR" ]; then
      echo "Error: Profile directory '$PROFILE_DIR' does not exist." >&2
      exit 1
  fi

  echo "==> Building profile: $PROFILE"

  # 1. Run pre-build hook if present and executable
  if [ -x "$PROFILE_DIR/.hooks/pre-build" ]; then
    echo "-> Running pre-build hook for $PROFILE..."
    "$PROFILE_DIR/.hooks/pre-build"
  fi

  # 2. Transpile all butane fragments in this profile (excluding .enc.bu and main.bu)
  mapfile -t FRAGMENTS < <(find "$PROFILE_DIR" -type f -name "*.bu" ! -name "*.enc.bu" ! -name "main.bu" | sort)
  for FILE in "${FRAGMENTS[@]}"; do
    just build-ignition "$FILE" "$PROFILE_DIR"
  done

  # 3. Transpile main.bu if it exists
  MAIN_FILE="$PROFILE_DIR/main.bu"
  if [ -f "$MAIN_FILE" ]; then
    just build-ignition "$MAIN_FILE" "$PROFILE_DIR"
  fi

  # 4. Run post-build hook if present and executable
  if [ -x "$PROFILE_DIR/.hooks/post-build" ]; then
    echo "-> Running post-build hook for $PROFILE..."
    "$PROFILE_DIR/.hooks/post-build"
  fi

# Helper for build recipe.
[linux]
[no-cd]
[private]
build-ignition $FILE FILES_DIR='.':
  #!/usr/bin/env bash

  set -euo pipefail

  # Determine if yamllint is installed locally.
  HAS_BUTANE=1
  if which butane &>/dev/null; then
    HAS_BUTANE=0
  fi

  # Set up file path for Ignition file.
  # Path should match the Butane file unless it is `main.bu`. In that case, the
  # Ignition file should be named after the parent folder name which represents
  # the server.
  IGNITION_FILE="${FILE%.bu}.ign"
  if [ "$(basename $FILE)" == "main.bu" ]; then
    IGNITION_FILE="${IGNITION_FILE%/*}.ign"
  fi
  mkdir -p "$(dirname $IGNITION_FILE)"

  # Generate Ignition file.
  echo "Generating ignition file: $IGNITION_FILE"
  if [ $HAS_BUTANE -eq 0 ]; then
    butane --pretty --files-dir "{{ FILES_DIR }}" < "${FILE}" > "$IGNITION_FILE"
  else
    podman run --rm -i -v .:/files:z,rw,rslave,rbind --workdir /files quay.io/coreos/butane:release \
      --pretty --files-dir "{{ FILES_DIR }}" < "${FILE}" > "$IGNITION_FILE"
  fi

# Hosts the ignition files for deployment
[linux]
[no-cd]
[group('Build & Provisioning')]
serve:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Spin up a Python HTTP server to serve the Ignition files.
  pushd servers &> /dev/null
  python3 -m http.server

# Validate generated ignition files
[linux]
[no-cd]
[group('Build & Provisioning')]
validate:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/ignition-validate:release > /dev/null

  # Validate the merged Ignition files.
  if [ -d "servers" ]; then
    for FILE in servers/*.ign; do
      if [ -s "$FILE" ]; then
        just validate-ignition "$FILE"
      else
        just display-error "The merged ignition file ($FILE) is empty or does not exist."
        exit 1
      fi
    done
  else
    just display-error "Unable to locate ignition files directory."
    exit 1
  fi

# Helper for validate recipe.
[linux]
[no-cd]
[private]
validate-ignition $FILE:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Validate Ignition file.
  echo "Validating ignition file: $FILE"
  podman run --rm -i quay.io/coreos/ignition-validate:release - < "$FILE"
