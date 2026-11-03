import "linux/helpers.just"
import "shared/output.just"

# Transpiles butane configuration(s) to create ignition file(s)
[linux]
[no-cd]
[group('Build & Provisioning')]
build:
  #!/usr/bin/env bash
  set -euo pipefail
  shopt -s globstar

  podman pull -q quay.io/coreos/butane:release > /dev/null

  JOBS=()
  MAX_JOBS=8
  JOBS_STATUS=0

  # Find & transpile butane fragments in servers/ directories recursively.
  mapfile -t FRAGMENTS < <(ls -1 servers/**/*.bu 2>/dev/null | grep -v '\.enc\.bu$' | grep -v '/main\.bu$' | sort)
  for FILE in "${FRAGMENTS[@]}"; do  
    while (( ${#JOBS[@]} >= MAX_JOBS )); do
      for INDEX in ${!JOBS[@]}; do
        if wait "${JOBS[$INDEX]}"; then
          unset 'JOBS[INDEX]'
        else
          JOBS_STATUS=1
        fi
      done
      JOBS=("${JOBS[@]}")
      sleep 0.1
    done
  
    PROFILE_DIR="$(dirname "$FILE")"
    just build-ignition "$FILE" "$PROFILE_DIR" &
    JOBS+=("$!")
  done

  while (( ${#JOBS[@]} > 0 )); do
    for INDEX in ${!JOBS[@]}; do
      if wait "${JOBS[$INDEX]}"; then
        unset 'JOBS[INDEX]'
      else
        JOBS_STATUS=1
      fi
    done
  done

  if [ $JOBS_STATUS -ne 0 ]; then
    just display-error "An error occurred while building ignition fragment files."
    exit $JOBS_STATUS
  fi

  # Find & transpile the main.bu for each server configuration
  mapfile -t MAINS < <(ls -1 servers/**/main.bu 2>/dev/null | sort)
  for FILE in "${MAINS[@]}"; do
    PROFILE_DIR="$(dirname "$FILE")"
    
    # Compile directly using the staged main.bu and its co-located .ign fragments
    just build-ignition "$FILE" "$PROFILE_DIR"
  done
  
# Remove all rendered ignition files.
[linux]
[no-cd]
[group('Maintenance & Utility')]
clean:
  @rm -rf .generated

# Decrypt all Butane files using Mozilla SOPS and the private age key from Bitwarden
[linux]
[no-cd]
[group('Secrets & Key Management')]
decrypt profile:
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

  ITEM_NAME="{{profile}}-age-key"

  echo "==> Fetching latest age private key from Bitwarden for '$ITEM_NAME'..."
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

  export SOPS_AGE_KEY="$PRIV_KEY_CONTENT"

  SERVERS_DIR="servers/{{profile}}"
  if [ ! -d "$SERVERS_DIR" ]; then
      echo "Error: Directory '$SERVERS_DIR' does not exist." >&2
      exit 1
  fi

  echo "==> Finding and decrypting all .enc.bu files in $SERVERS_DIR..."
  
  while IFS= read -r -d '' input_file; do
      output_file="${input_file%.enc.bu}.bu"
      
      echo "    Decrypting: $input_file -> $output_file"
      {
        echo "---"
        sops decrypt --input-type yaml --output-type yaml "$input_file" | \
          yq eval --indent 2 '.' - 
      } > "$output_file"
  done < <(find "$SERVERS_DIR" -type f -name "*.enc.bu" -print0)

  echo "Success! All Butane files decrypted successfully."

# Detects differences between encrypted files and their co-located unencrypted copies for a profile
[linux]
[no-cd]
[group('Verification & Diagnostics')]
diff profile:
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE_DIR="servers/{{ profile }}"
  if [ ! -d "$PROFILE_DIR" ]; then
      echo "Error: Directory '$PROFILE_DIR' does not exist." >&2
      exit 1
  fi

  # Ensure Bitwarden is unlocked and grab private key once for the session
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

  ITEM_NAME="{{ profile }}-age-key"
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

  export SOPS_AGE_KEY="$PRIV_KEY_CONTENT"

  HAS_DIFF=0
  shopt -s globstar
  while IFS= read -r -d '' enc_file; do
      echo "==> Checking diff for: $enc_file"
      if ! just diff-file "{{ profile }}" "$enc_file"; then
          HAS_DIFF=1
      fi
  done < <(find "$PROFILE_DIR" -type f -name "*.enc.bu" -print0)
  shopt -u globstar

  if [ $HAS_DIFF -eq 0 ]; then
      echo "==> No changes found between encrypted and unencrypted files for '{{ profile }}'."
  else
      echo "==> Differences detected."
  fi

# Decrypts an encrypted file to a temporary location and compares it with its unencrypted counterpart
[linux]
[no-cd]
[group('Verification & Diagnostics')]
diff-file profile enc_path:
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{ profile }}"
  ENC_PATH="{{ enc_path }}"
  UNENC_PATH="${ENC_PATH%.enc.bu}.bu"

  if [ ! -f "$UNENC_PATH" ]; then
      echo "Error: Unencrypted counterpart '$UNENC_PATH' does not exist." >&2
      exit 1
  fi

  # If SOPS_AGE_KEY is not already exported in the environment, fetch it from Bitwarden
  if [ -z "${SOPS_AGE_KEY:-}" ]; then
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

      ITEM_NAME="${PROFILE}-age-key"
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

      export SOPS_AGE_KEY="$PRIV_KEY_CONTENT"
  fi

  # Create a temporary file for decrypted output normalization
  TEMP_DEC=$(mktemp)
  trap 'rm -f "$TEMP_DEC"' EXIT

  {
    echo "---"
    sops decrypt --input-type yaml --output-type yaml "$ENC_PATH" | \
      yq eval --indent 2 '.' -
  } > "$TEMP_DEC"

  # Compare normalized decrypted content against the live unencrypted file
  if diff -u "$UNENC_PATH" "$TEMP_DEC"; then
      echo "    No changes in $ENC_PATH"
      exit 0
  else
      echo "    Changes detected in $ENC_PATH"
      exit 1
  fi

# Detects configuration drift against target infrastructure
[linux]
[no-cd]
[group('Verification & Diagnostics')]
drift profile:
  #!/usr/bin/env bash

  set -euo pipefail

  # Track overall status
  EQUAL="true"

  # Enable globstar to find files
  shopt -s globstar

  # Examine each configuration file.
  for FILE in servers/{{ profile }}/**/*.bu; do

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
        just -q is-content-overwritten {{ profile }} "$FILE" "$CONFIGFILE" || EQUAL="false"
      elif [ "$APPEND" == "true" ]; then
        just -q is-content-appended {{ profile }} "$FILE" "$CONFIGFILE" || EQUAL="false"
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

# Selectively encrypts modified Butane files using Mozilla SOPS, age from Bitwarden, and comment exclusion rules
[linux]
[no-cd]
[group('Secrets & Key Management')]
encrypt profile:
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

  ITEM_NAME="{{profile}}-age-key"

  echo "==> Fetching latest age keys from Bitwarden for '$ITEM_NAME'..."
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

  PRIV_KEY_CONTENT=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PrivateKey") | .value')
  if [ -n "$PRIV_KEY_CONTENT" ] && [ "$PRIV_KEY_CONTENT" != "null" ]; then
      export SOPS_AGE_KEY="$PRIV_KEY_CONTENT"
  fi

  SERVERS_DIR="servers/{{profile}}"
  if [ ! -d "$SERVERS_DIR" ]; then
      echo "Error: Directory '$SERVERS_DIR' does not exist." >&2
      exit 1
  fi

  echo "==> Finding and evaluating .bu files in $SERVERS_DIR for selective encryption..."
  
  shopt -s globstar
  while IFS= read -r -d '' input_file; do
      if [[ "$input_file" == *.enc.bu ]]; then
          continue
      fi

      output_file="${input_file%.bu}.enc.bu"

      # If the encrypted version exists, check if there are any differences
      if [ -f "$output_file" ]; then
          if just -q diff-file "{{profile}}" "$output_file"; then
              echo "    Skipping (no changes): $input_file"
              continue
          fi
      fi
      
      echo "    Encrypting (changed/new): $input_file ->$output_file"
      sops --encrypt \
        --input-type yaml \
        --output-type yaml \
        --age "$PUB_KEY_CONTENT" \
        "$input_file" > "$output_file"
  done < <(find "$SERVERS_DIR" -type f -name "*.bu" -print0)
  shopt -u globstar

  echo "Success! Modified Butane files encrypted successfully."

# Generates a post-quantum age key pair for encrypting and decrypting configuration files
[linux]
[no-cd]
[group('Secrets & Key Management')]
generate-age-key profile:
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

  ITEM_NAME="{{profile}}-age-key"

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
      --arg username "{{profile}}" \
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
lint:
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
  readarray -t BUTANE_FILES < <(ls -1 servers/**/*.bu 2>/dev/null | grep -v '\.enc\.bu$' | sort)

  if [ $HAS_YAMLLINT -ne 0 ]; then
    podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "${BUTANE_FILES[@]}"
  else
    yamllint "${BUTANE_FILES[@]}"
  fi

  echo "All preprocessed butane files passed linting checks."

# Rotate an existing age key with a new post-quantum keypair and update its entry in Bitwarden
[linux]
[no-cd]
[group('Secrets & Key Management')]
rotate-age-key profile:
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

  ITEM_NAME="{{profile}}-age-key"

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
      --arg username "{{profile}}" \
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
