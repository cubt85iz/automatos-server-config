import "shared/output.just"
import "secrets.just"

# Generates a post-quantum age key pair for encrypting and decrypting configuration files
[linux]
[no-cd]
[group('Secrets & Key Management')]
generate-age-key profile:
  #!/usr/bin/env bash
  set -euo pipefail

  # Determine if Bitwarden CLI is logged in
  BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
  if [ "$BW_STATUS" = "unauthenticated" ]; then
      echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
      exit 1
  fi

  # Determine if Bitwarden vault is locked and unlock if necessary
  WAS_LOCKED=false
  if [ "$BW_STATUS" = "locked" ]; then
      echo "==> Bitwarden vault is locked. Prompting to unlock..."
      export BW_SESSION=$(bw unlock --raw)
      WAS_LOCKED=true
  fi

  # Set up a trap to lock the Bitwarden vault on exit if it was originally locked
  if [ "$WAS_LOCKED" = "true" ]; then
      trap 'if [ "$WAS_LOCKED" = "true" ]; then echo "==> Locking Bitwarden vault..."; bw lock >/dev/null 2>&1 || true; fi' EXIT
  fi

  ITEM_NAME="{{profile}}-age-key"

  # Check if the Bitwarden item already exists to prevent accidental key rotation
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

  # Upload the generated keys to Bitwarden, using sensitive fields to maintain history of keypairs.
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
              {name: "PublicKey", value: $pub, type: 1},
              {name: "PrivateKey", value: $priv, type: 1}
          ]
      }')

  ENCODED=$(bw encode <<< "$PAYLOAD")
  bw create item "$ENCODED" >/dev/null
  echo "Success! Created Bitwarden item: $ITEM_NAME"

# Checks if a profile's encrypted files are out of sync with .sops.yaml
[linux]
[no-cd]
[group('Secrets & Key Management')]
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

  # Extract expected age keys by outputting as JSON from yq and normalizing with jq
  RAW_AGE=$(TEST_FILE="$TEST_FILE" yq eval -o=json '.creation_rules[] | select(strenv(TEST_FILE) | test(.path_regex)) | .age' "$SOPS_YAML")
  
  EXPECTED_KEYS=$(echo "$RAW_AGE" | jq -r '
    if type == "array" then .[] 
    elif type == "string" then split(",")[] 
    else empty end
  ' | sort | tr -d '[:space:]')

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
      echo "    Action: Run 'just encrypt {{ profile }}' to re-encrypt the profile with the latest published keys."
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
      # Determine if Bitwarden CLI is logged in
      BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
      if [ "$BW_STATUS" = "unauthenticated" ]; then
          echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
          exit 1
      fi

      # Determine if Bitwarden vault is locked and unlock if necessary
      WAS_LOCKED=false
      if [ "$BW_STATUS" = "locked" ]; then
          echo "==> Bitwarden vault is locked. Prompting to unlock..."
          export BW_SESSION=$(bw unlock --raw)
          WAS_LOCKED=true
      fi

      # Set up a trap to lock the Bitwarden vault on exit if it was originally locked
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

  # Abort if public key is empty or null
  if [ -z "$PUB_KEY" ] || [ "$PUB_KEY" == "null" ]; then
      echo "Error: No public key provided or found in Bitwarden." >&2
      exit 1
  fi

  # Create .sops.yaml if it does not exist
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

  # Determine if Bitwarden CLI is logged in
  BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
  if [ "$BW_STATUS" = "unauthenticated" ]; then
      echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
      exit 1
  fi

  # Determine if Bitwarden vault is locked and unlock if necessary
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
  TEMP_PARENT=""
  BACKUP_DIR=""

  # Unified EXIT trap to ensure sandbox cleanup AND Bitwarden locking always occur on error/exit
  trap '
    rm -rf "${TEMP_PARENT:-}" "${BACKUP_DIR:-}"
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
  TEMP_PARENT=$(mktemp -d)
  TEMP_DIR="$TEMP_PARENT/$PROFILE_DIR"
  mkdir -p "$TEMP_DIR"

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
              {name: "PublicKey", value: $pub, type: 1},
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
  rm -rf "$TEMP_PARENT"

  # Clear variables so trap does not try to clean up non-existent dirs
  TEMP_PARENT=""
  BACKUP_DIR=""

  # Reset trap once everything has succeeded and cleaned up cleanly
  trap - EXIT

  # Lock Bitwarden explicitly on success if it was locked originally
  if [ "$WAS_LOCKED" = "true" ]; then
      echo "==> Locking Bitwarden vault..."
      bw lock >/dev/null 2>&1 || true
  fi

  echo "Success! Rotated age key safely and atomically for: $ITEM_NAME"

# Unpublishes a profile's public key from .sops.yaml
[linux]
[no-cd]
[group('Secrets & Key Management')]
unpublish-key profile pubkey="":
  #!/usr/bin/env bash
  set -euo pipefail

  PROFILE="{{profile}}"
  PUB_KEY="{{pubkey}}"

  # Fetch the public key from Bitwarden if not provided
  if [ -z "$PUB_KEY" ]; then
      # Determine if Bitwarden CLI is logged in
      BW_STATUS=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
      if [ "$BW_STATUS" = "unauthenticated" ]; then
          echo "Error: Bitwarden CLI is not logged in. Please run 'bw login' first." >&2
          exit 1
      fi

      # Determine if Bitwarden vault is locked and unlock if necessary
      WAS_LOCKED=false
      if [ "$BW_STATUS" = "locked" ]; then
          echo "==> Bitwarden vault is locked. Prompting to unlock..."
          export BW_SESSION=$(bw unlock --raw)
          WAS_LOCKED=true
      fi

      # Set up a trap to lock the Bitwarden vault on exit if it was originally locked
      if [ "$WAS_LOCKED" = "true" ]; then
          trap 'if [ "$WAS_LOCKED" = "true" ]; then echo "==> Locking Bitwarden vault..."; bw lock >/dev/null 2>&1 || true; fi' EXIT
      fi

      ITEM_JSON=$(bw get item "${PROFILE}-age-key" 2>/dev/null || true)
      if [ -n "$ITEM_JSON" ]; then
          PUB_KEY=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.name == "PublicKey") | .value // empty')
      fi
  fi

  # Abort if .sops.yaml does not exist
  SOPS_YAML=".sops.yaml"
  if [ ! -f "$SOPS_YAML" ]; then
      echo "Error: $SOPS_YAML does not exist." >&2
      exit 1
  fi

  export REGEX="servers/${PROFILE}/.*\.bu$"
  export KEY="$PUB_KEY"

  # Verify that the key actually exists under the creation rule for this profile before modifying
  MATCH_COUNT=$(yq eval '[.creation_rules[] | select(.path_regex == env(REGEX)) | .age[] | select(. == env(KEY))] | length' "$SOPS_YAML")

  if [ "$MATCH_COUNT" -eq 0 ]; then
      echo "Error: Public key '$PUB_KEY' is not associated with profile '$PROFILE' in $SOPS_YAML." >&2
      exit 1
  fi

  # Remove the public key from the creation rule for this profile in .sops.yaml
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
