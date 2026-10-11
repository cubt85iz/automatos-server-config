import "linux/helpers.just"
import "shared/output.just"

# Transpiles butane configuration(s) to create ignition file(s)
[linux]
[no-cd]
[group('Build & Provisioning')]
build: preprocess-templates
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Enable advanced globbing
  shopt -s globstar

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/butane:release > /dev/null

  # Setup jobs
  JOBS=()
  MAX_JOBS=8
  JOBS_STATUS=0

  # Find & transpile non-primary butane files from staging.
  readarray -t BUTANE_FILES < <(ls -1 .staging/config/**/*.bu | grep -v main.bu | sort -r)
  for FILE in ${BUTANE_FILES[@]}; do
    # Do not exceed max jobs. Wait for one to complete before proceeding.
    while (( ${#JOBS[@]} >= MAX_JOBS )); do
      for INDEX in ${!JOBS[@]}; do
        if wait "${JOBS[$INDEX]}"; then
          unset 'JOBS[INDEX]'
        else
          JOBS_STATUS=1
        fi
      done

      # Compact the array and sleep briefly.
      JOBS=("${JOBS[@]}")
      sleep 0.1
    done
  
    # Pass .staging as the base files-dir so relative config/... paths resolve correctly
    just build-ignition "$FILE" ".staging" &
    JOBS+=("$!")
  done

  # Wait for any remaining jobs to complete before proceeding.
  while (( ${#JOBS[@]} > 0 )); do
    for INDEX in ${!JOBS[@]}; do
      if wait "${JOBS[$INDEX]}"; then
        unset 'JOBS[INDEX]'
      else
        JOBS_STATUS=1
      fi
    done
  done

  # Exit if an error occurred while processing non-primary butane files.
  if [ $JOBS_STATUS -ne 0 ]; then
    just display-error "An error occurred while building ignition files."
    exit $JOBS_STATUS
  fi

  # Find & transpile primary butane files for server configurations from staging.
  readarray -t BUTANE_FILES < <(ls -1 .staging/config/**/main.bu | sort -r)
  for FILE in ${BUTANE_FILES[@]}; do
    # Pass .staging as FILES_DIR so paths relative to config/ resolve correctly
    just build-ignition "$FILE" ".generated"
  done

# Remove all rendered ignition files.
[linux]
[no-cd]
[group('Maintenance & Utility')]
clean:
  @rm -rf .generated .staging

# Creates archives for configurations
[linux]
[no-cd]
create-archives *config:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Create directory for archives
  mkdir -p config/.archives

  FOLDERS=()
  if [ -z "{{ config }}" ]; then

    # Read list of folders in `config` into array
    readarray -t FOLDERS < <(ls -1 -d config/*/)
  else

    # Read list of configs from command-line
    read -a FOLDERS <<< "{{ config }}"
    FOLDERS=(${FOLDERS[@]/#/config\/})
    FOLDERS=(${FOLDERS[@]/%/\/})
  fi

  # Iterate over array and create archives.
  for FOLDER in "${FOLDERS[@]}"; do
    ARCHIVE="config/.archives/$(basename $FOLDER).tar"
    PATTERN=${FOLDER%*/}*
    tar cf "$ARCHIVE" $PATTERN
    echo "Created archive: $ARCHIVE"
  done

# Decrypt secrets.enc.yaml using Mozilla SOPS and the post-quantum age private key from Bitwarden
[linux]
[no-cd]
[group('Secrets & Key Management')]
decrypt-secrets folder input="secrets.enc.yaml" output="secrets.yaml":
  #!/usr/bin/env bash
  set -euo pipefail

  BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
  if [ "$BW_STATUS" = "unauthenticated" ]; then
      echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
      exit 1
  fi

  WAS_LOCKED=false
  if [ "$BW_STATUS" = "locked" ]; then
      echo "==> Bitwarden vault is locked. Prompting to unlock..."
      export BW_SESSION=$(bw unlock --raw)
      WAS_LOCKED=true
  fi

  # Ensure locking on exit if vault was unlocked during execution
  trap 'if [ "$WAS_LOCKED" = "true" ]; then echo "==> Locking Bitwarden vault..."; bw lock >/dev/null 2>&1 || true; fi' EXIT

  ITEM_NAME="{{folder}}-age-key"

  echo "==> Fetching latest age private key from Bitwarden..."
  ITEM_JSON=$(bw get item "$ITEM_NAME" 2>/dev/null || true)
  if [ -z "$ITEM_JSON" ]; then
      echo "Error: Bitwarden item '$ITEM_NAME' not found." >&2
      exit 1
  fi

  PRIV_KEY_CONTENT=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PrivateKey") | .value')

  if [ -z "$PRIV_KEY_CONTENT" ] || [ "$PRIV_KEY_CONTENT" == "null" ]; then
      echo "Error: PrivateKey field not found in Bitwarden item '$ITEM_NAME'." >&2
      exit 1
  fi

  # Clean up path variables
  CONFIG_DIR="config/{{folder}}"
  INPUT_FILE="$CONFIG_DIR/{{input}}"
  OUTPUT_FILE="$CONFIG_DIR/{{output}}"
  
  if [ ! -f "$INPUT_FILE" ]; then
      echo "Error: Input file '$INPUT_FILE' does not exist." >&2
      exit 1
  fi

  echo "==> Decrypting $INPUT_FILE into $OUTPUT_FILE using SOPS with age..."
  SOPS_AGE_KEY="$PRIV_KEY_CONTENT" sops --decrypt "$INPUT_FILE" > "$OUTPUT_FILE"
  echo "Success! Decrypted file: $OUTPUT_FILE"

[linux]
[no-cd]
[group('Verification & Diagnostics')]
diff server:
  #!/usr/bin/env bash

  set -euo pipefail

  # Track overall status
  EQUAL="true"

  # Enable globstar to find files
  shopt -s globstar

  # Examine each configuration file.
  for FILE in config/{{ server }}/**/*.bu; do

    # Store all paths found in the current configuration file.
    readarray -t CONFIGFILES < <(yq -r '.storage.files[].path' "$FILE")

    # Examine each file found in the current configuration file.
    for CONFIGFILE in ${CONFIGFILES[@]}; do

      # Continue if file is ignored in .diffignore
      ! just -q is-file-ignored "$CONFIGFILE" || continue

      # Determine what kind of operation to perform. Overwrite the contents of the file or append to it.
      OVERWRITE=$(yq eval "(.storage.files[] | select(.path == \"$CONFIGFILE\") | has(\"contents\"))" "$FILE")
      APPEND=$(yq eval "(.storage.files[] | select(.path == \"$CONFIGFILE\") | has(\"append\"))" "$FILE")

      if [ "$OVERWRITE" == "true" ]; then
        just -q is-content-overwritten {{ server }} "$FILE" "$CONFIGFILE" || EQUAL="false"
      elif [ "$APPEND" == "true" ]; then
        just -q is-content-appended {{ server }} "$FILE" "$CONFIGFILE" || EQUAL="false"
      else
        just display-error "Unable to process file: $CONFIGFILE"
        EQUAL="false"
      fi
    done
  done

  # Disable globstar
  shopt -u globstar

  # Exit unsuccessfully if not equal
  if [ "$EQUAL" != "true" ]; then
    just display-error "Configuration drift has been detected."
    exit 1
  fi

# Download latest stable Fedora CoreOS ISO
[linux]
[no-cd]
[group('Maintenance & Utility')]
download-iso:
  @podman run --pull always --rm -v .:/data -w /data quay.io/coreos/coreos-installer:release download -f iso

# Encrypt secrets.yaml using Mozilla SOPS and the post-quantum age public key from Bitwarden
[linux]
[no-cd]
[group('Secrets & Key Management')]
encrypt-secrets folder input="secrets.yaml" output="secrets.enc.yaml":
  #!/usr/bin/env bash
  set -euo pipefail

  BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
  if [ "$BW_STATUS" = "unauthenticated" ]; then
      echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
      exit 1
  fi

  WAS_LOCKED=false
  if [ "$BW_STATUS" = "locked" ]; then
      echo "==> Bitwarden vault is locked. Prompting to unlock..."
      export BW_SESSION=$(bw unlock --raw)
      WAS_LOCKED=true
  fi

  if [ "$WAS_LOCKED" = "true" ]; then
      trap 'if [ "$WAS_LOCKED" = "true" ]; then echo "==> Locking Bitwarden vault..."; bw lock >/dev/null 2>&1 || true; fi' EXIT
  fi

  ITEM_NAME="{{folder}}-age-key"

  echo "==> Fetching latest age public key from Bitwarden for '$ITEM_NAME'..."
  ITEM_JSON=$(bw get item "$ITEM_NAME" 2>/dev/null || true)
  if [ -z "$ITEM_JSON" ]; then
      echo "Error: Bitwarden item '$ITEM_NAME' not found." >&2
      exit 1
  fi

  PUB_KEY_CONTENT=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PublicKey") | .value')
  if [ -z "$PUB_KEY_CONTENT" ] || [ "$PUB_KEY_CONTENT" == "null" ]; then
      echo "Error: PublicKey field not found in Bitwarden item '$ITEM_NAME'." >&2
      exit 1
  fi

  # Clean up path variables
  CONFIG_DIR="config/{{folder}}"
  INPUT_FILE="$CONFIG_DIR/{{input}}"
  OUTPUT_FILE="$CONFIG_DIR/{{output}}"
  
  if [ ! -f "$INPUT_FILE" ]; then
      echo "Error: Input file '$INPUT_FILE' does not exist." >&2
      exit 1
  fi

  echo "==> Encrypting $INPUT_FILE into $OUTPUT_FILE using SOPS with age..."
  sops --encrypt --age "$PUB_KEY_CONTENT" "$INPUT_FILE" > "$OUTPUT_FILE"
  echo "Success! Created encrypted file: $OUTPUT_FILE"

# Extract archives for configurations
[linux]
[no-cd]
extract-archives *config:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  ARCHIVES=()
  if [ -z "{{ config }}" ]; then
    readarray -t ARCHIVES < <(ls -1 {{ justfile_directory() }}/config/.archives/*.tar)
  else
    read -a ARCHIVES <<< "{{ config }}"
    ARCHIVES=(${ARCHIVES[@]/#/config\/.archives\/})
    ARCHIVES=(${ARCHIVES[@]/%/.tar})
  fi

  # Iterate over array and extract archives.
  for ARCHIVE in "${ARCHIVES[@]}"; do
    tar xf "$ARCHIVE" -C "{{ justfile_directory() }}"
    echo "Extracted archive: $ARCHIVE"
  done

# Generates a post-quantum age key pair for encrypting and decrypting configuration files
[linux]
[no-cd]
[group('Secrets & Key Management')]
generate-age-key folder:
  #!/usr/bin/env bash
  set -euo pipefail

  BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
  if [ "$BW_STATUS" = "unauthenticated" ]; then
      echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
      exit 1
  fi

  WAS_LOCKED=false
  if [ "$BW_STATUS" = "locked" ]; then
      echo "==> Bitwarden vault is locked. Prompting to unlock..."
      export BW_SESSION=$(bw unlock --raw)
      WAS_LOCKED=true
  fi

  if [ "$WAS_LOCKED" = "true" ]; then
      trap 'if [ "$WAS_LOCKED" = "true" ]; then echo "==> Locking Bitwarden vault..."; bw lock >/dev/null 2>&1 || true; fi' EXIT
  fi

  ITEM_NAME="{{folder}}-age-key"

  echo "==> Checking if Bitwarden item '$ITEM_NAME' already exists..."
  if bw list items --search "$ITEM_NAME" 2>/dev/null | jq -e --arg name "$ITEM_NAME" 'any(.[] ; .name == $name)' >/dev/null; then
      echo "Error: Bitwarden item '$ITEM_NAME' already exists. Aborting to prevent key rotation." >&2
      exit 1
  fi

  echo "==> Generating post-quantum age key pair (ML-KEM-768 + X25519)..."
  AGE_OUTPUT=$(age-keygen -pq)
  PUB_KEY=$(echo "$AGE_OUTPUT" | grep '^# public key:' | cut -d' ' -f4)
  PRIV_KEY=$(echo "$AGE_OUTPUT" | grep '^AGE-SECRET-KEY')

  if [ -z "$PUB_KEY" ] || [ -z "$PRIV_KEY" ]; then
      echo "Error: Failed to generate age keypair." >&2
      exit 1
  fi

  echo "==> Uploading post-quantum credentials and keys to Bitwarden..."
  PAYLOAD=$(jq -n \
      --arg name "$ITEM_NAME" \
      --arg username "{{folder}}" \
      --arg pub "$PUB_KEY" \
      --arg priv "$PRIV_KEY" \
      '{
          type: 1,
          name: $name,
          notes: "Automated post-quantum age key generation via just",
          login: {
              username: $username
          },
          fields: [
              {name: "PublicKey", value: $pub, type: 0},
              {name: "PrivateKey", value: $priv, type: 1}
          ]
      }')

  ENCODED=$(bw encode <<< "$PAYLOAD")
  bw create item "$ENCODED" >/dev/null
  echo "Success! Created Bitwarden item: $ITEM_NAME"

# Lints butane file using yamllint.
[linux]
[no-cd]
[group('Verification & Diagnostics')]
lint: preprocess-templates
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Determine if yamllint is installed locally.
  HAS_YAMLLINT=1
  if which yamllint &>/dev/null; then
    HAS_YAMLLINT=0
  fi

  # Pull the yamllint docker image if yamllint is not installed.
  if [ $HAS_YAMLLINT -ne 0 ]; then
    podman pull -q docker.io/pipelinecomponents/yamllint:latest > /dev/null
  fi

  shopt -s globstar
  readarray -t BUTANE_FILES < <(ls -1 .staging/config/**/*.bu | sort -r)

  if [ $HAS_YAMLLINT -ne 0 ]; then
    podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "${BUTANE_FILES[@]}"
  else
    yamllint "${BUTANE_FILES[@]}"
  fi

  echo "All preprocessed butane files passed linting checks."

# Rebuilds the custom Containerfile image and reprovisions the Toolbx container
[linux]
[no-cd]
[group('Maintenance & Utility')]
provision-toolbox:
  #!/usr/bin/env bash
  set -euo pipefail

  CONTAINER_NAME="fcos-builder"
  IMAGE_NAME="localhost/fcos-builder:latest"

  echo "==> Checking for existing Toolbx container '$CONTAINER_NAME'..."
  if podman ps -a --format '{{{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      echo "==> Removing existing container..."
      toolbox rm -f "$CONTAINER_NAME" 2>/dev/null || podman rm -f "$CONTAINER_NAME"
  fi

  echo "==> Building custom OCI image ($IMAGE_NAME)..."
  podman build -t "$IMAGE_NAME" .

  echo "==> Creating fresh Toolbx container..."
  toolbox create --container "$CONTAINER_NAME" --image "$IMAGE_NAME"

  echo "Success! Toolbx '$CONTAINER_NAME' has been successfully reprovisioned."
  
# Rotate an existing age key with a new post-quantum keypair and update its entry in Bitwarden
[linux]
[no-cd]
[group('Secrets & Key Management')]
rotate-age-key folder:
  #!/usr/bin/env bash
  set -euo pipefail

  BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
  if [ "$BW_STATUS" = "unauthenticated" ]; then
      echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
      exit 1
  fi

  WAS_LOCKED=false
  if [ "$BW_STATUS" = "locked" ]; then
      echo "==> Bitwarden vault is locked. Prompting to unlock..."
      export BW_SESSION=$(bw unlock --raw)
      WAS_LOCKED=true
  fi

  if [ "$WAS_LOCKED" = "true" ]; then
      trap 'if [ "$WAS_LOCKED" = "true" ]; then echo "==> Locking Bitwarden vault..."; bw lock >/dev/null 2>&1 || true; fi' EXIT
  fi

  ITEM_NAME="{{folder}}-age-key"

  echo "==> Checking if Bitwarden item '$ITEM_NAME' exists for rotation..."
  ITEM_JSON=$(bw get item "$ITEM_NAME" 2>/dev/null || true)
  if [ -z "$ITEM_JSON" ]; then
      echo "Error: Bitwarden item '$ITEM_NAME' does not exist. Use 'generate-age-key' to create it first." >&2
      exit 1
  fi

  ITEM_ID=$(echo "$ITEM_JSON" | jq -r '.id')

  echo "==> Generating new post-quantum age key pair (ML-KEM-768 + X25519)..."
  AGE_OUTPUT=$(age-keygen -pq)
  PUB_KEY=$(echo "$AGE_OUTPUT" | grep '^# public key:' | cut -d' ' -f4)
  PRIV_KEY=$(echo "$AGE_OUTPUT" | grep '^AGE-SECRET-KEY')

  if [ -z "$PUB_KEY" ] || [ -z "$PRIV_KEY" ]; then
      echo "Error: Failed to generate age keypair." >&2
      exit 1
  fi

  echo "==> Updating Bitwarden item '$ITEM_NAME' with the new post-quantum key..."
  PAYLOAD=$(jq -n \
      --arg id "$ITEM_ID" \
      --arg name "$ITEM_NAME" \
      --arg username "{{folder}}" \
      --arg pub "$PUB_KEY" \
      --arg priv "$PRIV_KEY" \
      '{
          id: $id,
          type: 1,
          name: $name,
          notes: "Rotated post-quantum age key via just",
          login: {
              username: $username
          },
          fields: [
              {name: "PublicKey", value: $pub, type: 0},
              {name: "PrivateKey", value: $priv, type: 1}
          ]
      }')

  ENCODED=$(bw encode <<< "$PAYLOAD")
  bw edit item "$ITEM_ID" "$ENCODED" >/dev/null
  echo "Success! Rotated age key and updated Bitwarden item: $ITEM_NAME"

# Hosts the ignition files for deployment
[linux]
[no-cd]
[group('Build & Provisioning')]
serve:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Spin up a Python HTTP server to serve the Ignition files.
  pushd .generated &> /dev/null
  python3 -m http.server

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
  if [ -d ".generated/config" ]; then
    for FILE in .generated/config/*.ign; do
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
