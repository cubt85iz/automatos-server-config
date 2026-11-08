import "shared/output.just"

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
  if ! diff -u "$TEMP_DEC" "$UNENC_PATH"; then
      echo "    Changes detected in $ENC_PATH"
      exit 1
  fi

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
  TEMP_PARENT=$(mktemp -d)
  TEMP_DIR="$TEMP_PARENT/$PROFILE_DIR"
  mkdir -p "$TEMP_DIR"

  # Unified EXIT trap to ensure temp sandbox cleanup AND Bitwarden locking always occur
  trap '
    rm -rf "'"${TEMP_PARENT:-}"'"
    if [ "'"${WAS_LOCKED}"'" = "true" ]; then
        echo "==> Locking Bitwarden vault..."
        bw lock >/dev/null 2>&1 || true
    fi
  ' EXIT

  # Copy profile contents recursively to temp staging area preserving path structure
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
  rm -rf "$TEMP_PARENT"

  # Reset trap once everything has succeeded and cleaned up cleanly
  trap - EXIT

  # Lock Bitwarden explicitly on success if it was locked originally
  if [ "$WAS_LOCKED" = "true" ]; then
      echo "==> Locking Bitwarden vault..."
      bw lock >/dev/null 2>&1 || true
  fi
  
  echo "Success! Butane files encrypted atomically for profile: ${PROFILE}"

