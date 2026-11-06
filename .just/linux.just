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
  #!/usr/bin/env bash
  set -euo pipefail

  find servers -type f -name "*.ign" -delete

# Decrypt all Butane files for a profile using atomic directory-level staging (with accidental overwrite protection)
[linux]
[no-cd]
[group('Secrets & Key Management')]
decrypt profile force="false":
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

  PROFILE="{{profile}}"
  FORCE="{{force}}"
  ITEM_NAME="${PROFILE}-age-key"

  PROFILE_DIR="servers/${PROFILE}"
  if [ ! -d "$PROFILE_DIR" ]; then
      echo "Error: Directory '$PROFILE_DIR' does not exist." >&2
      exit 1
  fi

  # Fetch key first so we can perform local edit checks
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

  # ACCIDENTAL OVERWRITE PROTECTION:
  # If not forced, check if any unencrypted .bu file has local modifications not yet encrypted.
  if [ "$FORCE" != "true" ]; then
      HAS_LOCAL_CHANGES=0
      shopt -s globstar
      while IFS= read -r -d '' enc_file; do
          unenc_file="${enc_file%.enc.bu}.bu"
          if [ -f "${unenc_file:-}" ]; then
              if ! just -q diff-file "${PROFILE}" "$enc_file" 2>/dev/null; then
                  rel_path="${enc_file#$PROFILE_DIR/}"
                  echo "    Warning: Local changes detected in unencrypted counterpart for: ${rel_path%.enc.bu}.bu"
                  HAS_LOCAL_CHANGES=1
              fi
          fi
      done < <(find "$PROFILE_DIR" -type f -name "*.enc.bu" -print0)
      shopt -u globstar

      if [ $HAS_LOCAL_CHANGES -eq 1 ]; then
          echo "" >&2
          echo "Error: Unencrypted local modifications detected in profile '${PROFILE}'." >&2
          echo "       Running decrypt would overwrite your workspace changes." >&2
          echo "       Run 'just encrypt ${PROFILE}' first to save them, or pass 'force=\"true\"' to override." >&2
          
          # Ensure vault locks before exiting on error
          if [ "$WAS_LOCKED" = "true" ]; then
              echo "==> Locking Bitwarden vault..."
              bw lock >/dev/null 2>&1 || true
          fi
          exit 1
      fi
  fi

  echo "==> Staging profile in a temporary directory for atomic decryption..."
  TEMP_DIR=$(mktemp -d)

  # Unified EXIT trap to ensure temp sandbox cleanup AND Bitwarden locking always occur
  trap '
    rm -rf "'"${TEMP_DIR:-}"'"
    if [ "'"${WAS_LOCKED}"'" = "true" ]; then
        echo "==> Locking Bitwarden vault..."
        bw lock >/dev/null 2>&1 || true
    fi
  ' EXIT

  # Copy ALL profile contents recursively to temp staging area (preserves both .enc.bu and main.bu)
  cp -a "$PROFILE_DIR/." "$TEMP_DIR/"

  shopt -s globstar
  while IFS= read -r -d '' input_file; do
      rel_path="${input_file#$TEMP_DIR/}"
      target_input="$TEMP_DIR/$rel_path"
      output_file="${target_input%.enc.bu}.bu"
      
      echo "    Decrypting: $rel_path -> $(basename "$output_file")"
      
      TEMP_DEC=$(mktemp)
      {
        echo "---"
        sops decrypt --input-type yaml --output-type yaml "$input_file" | \
          yq eval --indent 2 '.'
      } > "$TEMP_DEC"

      mv "$TEMP_DEC" "$output_file"
      # Note: target_input (.enc.bu) is left intact alongside the new .bu file
  done < <(find "$TEMP_DIR" -type f -name "*.enc.bu" -print0)
  shopt -u globstar

  # Atomically commit the successfully decrypted profile directory into place
  echo "==> Committing decrypted files atomically to $PROFILE_DIR..."
  BACKUP_DIR=$(mktemp -d)
  mv "$PROFILE_DIR" "$BACKUP_DIR/old"
  mv "$TEMP_DIR" "$PROFILE_DIR"
  rm -rf "$BACKUP_DIR"

  # Reset trap once everything has succeeded and cleaned up cleanly
  trap - EXIT
  
  # Lock Bitwarden explicitly on success if it was locked originally
  if [ "$WAS_LOCKED" = "true" ]; then
      echo "==> Locking Bitwarden vault..."
      bw lock >/dev/null 2>&1 || true
  fi

  echo "Success! All Butane files decrypted atomically for profile: ${PROFILE} (encrypted counterparts preserved)."

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
  if ! diff -u "$UNENC_PATH" "$TEMP_DEC"; then
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

# Selectively encrypts modified Butane files using Mozilla SOPS and .sops.yaml rules (atomic directory-level staging)
[linux]
[no-cd]
[group('Secrets & Key Management')]
encrypt profile force="false":
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{profile}}"
  PROFILE_DIR="servers/${PROFILE}"
  if [ ! -d "$PROFILE_DIR" ]; then
      echo "Error: Directory '$PROFILE_DIR' does not exist." >&2
      exit 1
  fi

  FORCE="{{force}}"

  WAS_LOCKED=false
  # Ensure private key is available if we need to check diffs
  if [ -z "${SOPS_AGE_KEY:-}" ]; then
      BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
      if [ "$BW_STATUS" = "authenticated" ]; then
          BW_SESSION=$(bw unlock --raw 2>/dev/null || true)
          [ -n "$BW_SESSION" ] && export BW_SESSION
      fi

      if [ "$BW_STATUS" = "locked" ]; then
          echo "==> Bitwarden vault is locked. Prompting to unlock..."
          export BW_SESSION=$(bw unlock --raw)
          WAS_LOCKED=true
      fi

      ITEM_JSON=$(bw get item "${PROFILE}-age-key" 2>/dev/null || true)
      PRIV_KEY_CONTENT=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PrivateKey") | .value // empty')
      [ -n "$PRIV_KEY_CONTENT" ] && export SOPS_AGE_KEY="$PRIV_KEY_CONTENT"
  fi

  # REKEY DRIFT CHECK:
  # If not forced, check if the encrypted files for the profile are out of sync with .sops.yaml.
  if [ "$FORCE" != "true" ]; then
      if ! just -q needs-rekey "${PROFILE}"; then
          echo "Error: Profile '${PROFILE}' has encrypted files out of sync with .sops.yaml (needs rekeying)." >&2
          echo "       Pass 'force=\"true\"' to override and re-encrypt the profile." >&2
          
          if [ "$WAS_LOCKED" = "true" ]; then
              echo "==> Locking Bitwarden vault..."
              bw lock >/dev/null 2>&1 || true
          fi
          exit 1
      fi
  fi

  echo "==> Staging profile in a temporary directory for atomic selective encryption..."
  TEMP_DIR=$(mktemp -d)

  # Unified EXIT trap to ensure temp sandbox cleanup AND Bitwarden locking always occur
  trap '
    rm -rf "'"${TEMP_DIR:-}"'"
    if [ "'"${WAS_LOCKED}"'" = "true" ]; then
        echo "==> Locking Bitwarden vault..."
        bw lock >/dev/null 2>&1 || true
    fi
  ' EXIT

  # Copy ALL profile contents recursively to temp staging area
  cp -a "$PROFILE_DIR/." "$TEMP_DIR/"

  shopt -s globstar
  while IFS= read -r -d '' input_file; do
      rel_path="${input_file#$TEMP_DIR/}"
      target_input="$TEMP_DIR/$rel_path"

      if [[ "$target_input" == *.enc.bu ]]; then
          continue
      fi

      target_output="${target_input%.bu}.enc.bu"
      live_output="$PROFILE_DIR/$rel_path"
      live_output="${live_output%.bu}.enc.bu"

      # If not forced and encrypted version exists live, check if there are differences
      if [ "$FORCE" != "true" ] && [ -f "$live_output" ]; then
          if just -q diff-file "${PROFILE}" "$live_output"; then
              echo "    Skipping (no changes): $rel_path"
              continue
          fi
      fi
      
      echo "    Encrypting (changed/new): $rel_path"
      sops --encrypt \
        --input-type yaml \
        --output-type yaml \
        "$target_input" > "$target_output"
  done < <(find "$TEMP_DIR" -type f -name "*.bu" -print0)
  shopt -u globstar

  # Atomically commit the successfully encrypted profile directory into place
  echo "==> Committing encrypted files atomically to $PROFILE_DIR..."
  BACKUP_DIR=$(mktemp -d)
  mv "$PROFILE_DIR" "$BACKUP_DIR/old"
  mv "$TEMP_DIR" "$PROFILE_DIR"
  rm -rf "$BACKUP_DIR"

  # Reset trap once everything has succeeded and cleaned up cleanly
  trap - EXIT

  # Lock Bitwarden explicitly on success if it was locked originally
  if [ "$WAS_LOCKED" = "true" ]; then
      echo "==> Locking Bitwarden vault..."
      bw lock >/dev/null 2>&1 || true
  fi
  
  echo "Success! Butane files encrypted atomically for profile: ${PROFILE}"

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

# Checks if a profile's encrypted files are out of sync with .sops.yaml
[linux]
[no-cd]
[group('Verification & Diagnostics')]
needs-rekey profile:
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{profile}}"
  PROFILE_DIR="servers/${PROFILE}"
  SOPS_YAML=".sops.yaml"

  if [ ! -d "$PROFILE_DIR" ]; then
      echo "Error: Directory '$PROFILE_DIR' does not exist." >&2
      exit 1
  fi

  if [ ! -f "$SOPS_YAML" ]; then
      echo "Error: $SOPS_YAML does not exist." >&2
      exit 1
  fi

  # Find a test file path for this profile to match against .sops.yaml creation rules
  TEST_FILE=$(find "$PROFILE_DIR" -type f -name "*.bu" | head -n 1)
  if [ -z "$TEST_FILE" ]; then
      echo "==> No Butane files found for profile '$PROFILE'."
      exit 0
  fi

  # Extract expected age keys by finding the rule whose path_regex matches a file in this profile
  # We evaluate this cleanly using yq by testing path matching against creation rules
  EXPECTED_KEYS=$(yq eval --arg test_path "$TEST_FILE" '
    .creation_rules[] | 
    select($test_path | test(.path_regex)) | 
    .age | 
    if type == "array" then .[] else . | split(",\\s*")[] end
  ' "$SOPS_YAML" | sort | tr -d '[:space:]')

  if [ -z "$EXPECTED_KEYS" ]; then
      echo "Warning: No matching creation rule found in $SOPS_YAML for profile '$PROFILE'."
      exit 1
  fi

  OUT_OF_SYNC=0
  echo "==> Checking key synchronization for profile: $PROFILE"

  # Iterate through ALL encrypted files to ensure complete profile coverage
  while IFS= read -r -d '' enc_file; do
      if [ ! -f "$enc_file" ]; then
          continue
      fi

      ACTUAL_KEYS=$(yq eval '.sops.age[].recipient' "$enc_file" 2>/dev/null | sort | tr -d '[:space:]' || echo "")

      if [ "$EXPECTED_KEYS" != "$ACTUAL_KEYS" ]; then
          echo "    [OUT OF SYNC] $enc_file headers do not match .sops.yaml"
          OUT_OF_SYNC=1
      else
          echo "    [OK]        $enc_file"
      fi
  done < <(find "$PROFILE_DIR" -type f -name "*.enc.bu" -print0)

  if [ $OUT_OF_SYNC -eq 0 ]; then
      echo "==> Status: All encrypted files are fully up to date."
      exit 0
  else
      echo ""
      echo "==> Status: DRIFT DETECTED. One or more files need to be rekeyed."
      echo "    Action: Run 'sops updatekeys <file>' or rotate/re-encrypt the profile."
      exit 1
  fi

# Publishes the public key for a profile to .sops.yaml
[linux]
[no-cd]
[group('Secrets & Key Management')]
publish-key profile pubkey="":
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{profile}}"
  PUB_KEY="{{pubkey}}"

  if [ -z "$PUB_KEY" ]; then
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

      ITEM_JSON=$(bw get item "${PROFILE}-age-key" 2>/dev/null || true)
      if [ -z "$ITEM_JSON" ]; then
          echo "Error: Bitwarden item '${PROFILE}-age-key' not found." >&2
          exit 1
      fi
      PUB_KEY=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PublicKey") | .value')
  fi

  if [ -z "$PUB_KEY" ] || [ "$PUB_KEY" == "null" ]; then
      echo "Error: No public key provided or found in Bitwarden." >&2
      exit 1
  fi

  SOPS_YAML=".sops.yaml"
  if [ ! -f "$SOPS_YAML" ]; then
      echo "creation_rules:" > "$SOPS_YAML"
  fi

  export REGEX="servers/${PROFILE}/.*\.bu$"
  export KEY="$PUB_KEY"
  
  RULE_EXISTS=$(yq eval '.creation_rules[]? | select(.path_regex == env(REGEX)) | length > 0' "$SOPS_YAML" 2>/dev/null || echo "false")

  if [ "$RULE_EXISTS" != "true" ]; then
      yq eval '.creation_rules += [{"path_regex": env(REGEX), "age": [env(KEY)]}]' \
          "$SOPS_YAML" -i
      echo "==> Added new rule for profile '$PROFILE' with key $PUB_KEY to $SOPS_YAML"
  else
      KEY_EXISTS=$(yq eval '.creation_rules[] | select(.path_regex == env(REGEX)) | .age | contains([env(KEY)])' \
          "$SOPS_YAML")
      if [ "$KEY_EXISTS" == "true" ]; then
          echo "==> Key is already published in $SOPS_YAML for profile '$PROFILE'."
      else
          yq eval 'with(.creation_rules[] | select(.path_regex == env(REGEX)); .age += [env(KEY)])' \
              "$SOPS_YAML" -i
          echo "==> Published new key for profile '$PROFILE' to $SOPS_YAML"
      fi
  fi

# Rotate an existing age key atomically: decrypts live, stages re-encryption in a temp dir, updates remote state, and swaps atomically
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

  PROFILE="{{profile}}"
  ITEM_NAME="${PROFILE}-age-key"

  echo "==> Checking if Bitwarden item '$ITEM_NAME' exists..."
  ITEM_JSON=$(bw get item "$ITEM_NAME" 2>/dev/null || true)
  if [ -z "$ITEM_JSON" ]; then
      echo "Error: Bitwarden item '$ITEM_NAME' does not exist. Use 'generate-age-key' first." >&2
      exit 1
  fi

  ITEM_ID=$(echo "$ITEM_JSON" | jq -r '.id')
  OLD_PUB_KEY=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PublicKey") | .value // empty')
  OLD_PRIV_KEY=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PrivateKey") | .value // empty')

  PROFILE_DIR="servers/${PROFILE}"
  if [ ! -d "$PROFILE_DIR" ]; then
      echo "Error: Directory '$PROFILE_DIR' does not exist." >&2
      exit 1
  fi

  # Initialize temp variables for safe cleanup trap scoping
  TEMP_DIR=""
  BACKUP_DIR=""

  # Unified EXIT trap to ensure sandbox cleanup AND Bitwarden locking always occur on error/exit
  trap '
    rm -rf "${TEMP_DIR:-}" "${BACKUP_DIR:-}"
    if [ "${WAS_LOCKED}" = "true" ]; then
        echo "==> Locking Bitwarden vault..."
        bw lock >/dev/null 2>&1 || true
    fi
  ' EXIT

  # 1. Decrypt existing files using the OLD private key while it is valid (uses atomic decrypt recipe)
  if [ -n "$OLD_PRIV_KEY" ] && [ "$OLD_PRIV_KEY" != "null" ]; then
      echo "==> Decrypting existing encrypted files with current private key..."
      export SOPS_AGE_KEY="$OLD_PRIV_KEY"
      just decrypt "${PROFILE}"
  fi

  # 2. Generate new keypair locally
  echo "==> Generating new post-quantum age key pair (ML-KEM-768 + X25519)..."
  AGE_OUTPUT=$(age-keygen -pq)
  PUB_KEY=$(echo "$AGE_OUTPUT" | grep '^# public key:' | cut -d' ' -f4)
  PRIV_KEY=$(echo "$AGE_OUTPUT" | grep '^AGE-SECRET-KEY')

  if [ -z "$PUB_KEY" ] || [ -z "$PRIV_KEY" ]; then
      echo "Error: Failed to generate age keypair." >&2
      exit 1
  fi

  # 3. Stage profile in a temporary directory and test-encrypt atomically with correct relative paths
  echo "==> Staging profile in a temporary directory for atomic re-encryption..."
  TEMP_DIR=$(mktemp -d)

  cp -a "$PROFILE_DIR/." "$TEMP_DIR/"

  shopt -s globstar
  while IFS= read -r -d '' input_file; do
      rel_path="${input_file#$TEMP_DIR/}"
      target_input="$TEMP_DIR/$rel_path"

      if [[ "$target_input" == *.enc.bu ]]; then
          continue
      fi
      target_output="${target_input%.bu}.enc.bu"

      sops --encrypt \
        --input-type yaml \
        --output-type yaml \
        --age "$PUB_KEY" \
        "$target_input" > "$target_output"
  done < <(find "$TEMP_DIR" -type f -name "*.bu" -print0)
  shopt -u globstar

  # 4. Now update Bitwarden item with the new key
  echo "==> Updating Bitwarden item '$ITEM_NAME' with the new key..."
  PAYLOAD=$(jq -n \
      --arg id "$ITEM_ID" \
      --arg name "$ITEM_NAME" \
      --arg username "${PROFILE}" \
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

  # 5. Update .sops.yaml config
  if [ -n "$OLD_PUB_KEY" ] && [ "$OLD_PUB_KEY" != "null" ]; then
      just unpublish-key "${PROFILE}" "$OLD_PUB_KEY" || true
  fi
  just publish-key "${PROFILE}" "$PUB_KEY"

  # 6. Atomically swap the staged encrypted profile directory into place
  echo "==> Committing rotated profile atomically to $PROFILE_DIR..."
  BACKUP_DIR=$(mktemp -d)
  mv "$PROFILE_DIR" "$BACKUP_DIR/old"
  mv "$TEMP_DIR" "$PROFILE_DIR"
  rm -rf "$BACKUP_DIR"

  # Clear variables so trap does not try to clean up non-existent dirs
  TEMP_DIR=""
  BACKUP_DIR=""

  # Reset trap once everything has succeeded and cleaned up cleanly
  trap - EXIT

  # Lock Bitwarden explicitly on success if it was locked originally
  if [ "$WAS_LOCKED" = "true" ]; then
      echo "==> Locking Bitwarden vault..."
      bw lock >/dev/null 2>&1 || true
  fi

  echo "Success! Rotated age key safely and atomically for: $ITEM_NAME"

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

# Unpublishes a profile's public key from .sops.yaml
[linux]
[no-cd]
[group('Secrets & Key Management')]
unpublish-key profile pubkey="":
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{profile}}"
  PUB_KEY="{{pubkey}}"

  if [ -z "$PUB_KEY" ]; then
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

      ITEM_JSON=$(bw get item "${PROFILE}-age-key" 2>/dev/null || true)
      if [ -n "$ITEM_JSON" ]; then
          PUB_KEY=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PublicKey") | .value // empty')
      fi
  fi

  SOPS_YAML=".sops.yaml"
  if [ ! -f "$SOPS_YAML" ]; then
      echo "Error: $SOPS_YAML does not exist." >&2
      exit 1
  fi

  export REGEX="servers/${PROFILE}/.*\.bu$"
  export KEY="$PUB_KEY"

  if [ -n "$PUB_KEY" ]; then
      yq eval 'del(.creation_rules[] | select(.path_regex == env(REGEX)) | .age[] | select(. == env(KEY)))' \
          "$SOPS_YAML" -i
      echo "==> Removed key $PUB_KEY from $SOPS_YAML for profile '$PROFILE'."
  fi

  # Clean up rule if age array is empty or missing
  EMPTY_RULE=$(yq eval '.creation_rules[] | select(.path_regex == env(REGEX)) | (.age | length == 0)' \
      "$SOPS_YAML" 2>/dev/null || echo "false")

  if [ "$EMPTY_RULE" == "true" ]; then
      yq eval '.creation_rules = [.creation_rules[] | select(.path_regex != env(REGEX))]' \
          "$SOPS_YAML" -i
      echo "==> Removed empty rule for profile '$PROFILE' from $SOPS_YAML"
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
