# Helper for build recipe.
[linux]
[no-cd]
[private]
build-ignition $FILE FILES_DIR='.':
  #!/usr/bin/env bash

  set -euo pipefail

  # Strip .staging/ prefix if present so output paths map correctly to .generated/
  CLEAN_FILE="${FILE#.staging/}"
  
  # Determine if yamllint is installed locally.
  HAS_BUTANE=1
  if which butane &>/dev/null; then
    HAS_BUTANE=0
  fi

  # Set up file path for Ignition file.
  # Path should match the Butane file unless it is `main.bu`. In that case, the
  # Ignition file should be named after the parent folder name which represents
  # the server.
  IGNITION_FILE=".generated/${CLEAN_FILE%.*}.ign"
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

[linux]
[no-cd]
[private]
is-content-appended $SERVER $FILE $CONFIGFILE:
  #!/usr/bin/env bash

  set -euo pipefail

  # Unlike `contents`, `append` is an array. Store content that should have been appended to the file.
  readarray -t APPENDEDCONTENT < <(yq -r ".storage.files[] | select(.path == \"$CONFIGFILE\") | .append[].inline" "$FILE")

  # If there is content to append to the file, then proceed.
  if (( ${#APPENDEDCONTENT[@]} > 0 )); then
    # Check for existence of the file on the server. If necessary, use `sudo`.
    if ssh $SERVER "test -e '$CONFIGFILE' || sudo test -e '$CONFIGFILE'"; then

      # Iterate over appended content and determine if the server file contains it. If the content
      # is missing, then add it to the `MISSING_CONTENT` array for displaying later.
      MISSING_CONTENT=()
      for CONTENT in "${APPENDEDCONTENT[@]}"; do
        if ! ssh $SERVER "grep -q \"$CONTENT\" \"$CONFIGFILE\""; then
          MISSING_CONTENT+=("$CONTENT")
        fi
      done

      # Diplay content missing from server file.
      if (( ${#MISSING_CONTENT[@]} > 0 )); then
        just display-error "Content missing from file: $CONFIGFILE"
        echo "Content:"
        echo "${MISSING_CONTENT[@]}"
        exit 1
      fi
    else
      just display-error "Unable to locate file on server: $CONFIGFILE"
      exit 1
    fi
  fi

  exit 0

[linux]
[no-cd]
[private]
is-content-overwritten $SERVER $FILE $CONFIGFILE:
  #!/usr/bin/env bash

  set -euo pipefail

  # Calculate checksum of file contents listed in the configuration file.
  CONTENT=$(yq -r ".storage.files[] | select(.path == \"$CONFIGFILE\") | .contents.inline // \"\"" "$FILE")

  # A file can be overwritten or appended. If `contents` have been provided then perform an equality
  # comparison of the contents of the file against the contents listed in the configuration file.
  if [ -n "$CONTENT" ]; then
    CONTENT_CSUM=$(sha256sum < <(echo "$CONTENT") | cut -d' ' -f1)

    # Check for existence of the file on the server. If necessary, use `sudo`.
    if ssh $SERVER "test -e '$CONFIGFILE' || sudo test -e '$CONFIGFILE'"; then

      # Calculate checksum of server content
      if SERVER_CSUM=$((ssh $SERVER "sha256sum '$CONFIGFILE' 2>/dev/null || \
        sudo sha256sum '$CONFIGFILE'") | cut -d' ' -f1); then

        # Test checksums for equality. If not equal, generate a diff to illustrate the differences.
        if [ "$CONTENT_CSUM" != "$SERVER_CSUM" ]; then
          just display-error "Content differs for file: $CONFIGFILE"
          if ! DIFFERENCE=$(ssh $SERVER "echo \"$CONTENT\" | sudo diff - \"$CONFIGFILE\""); then
            echo "$DIFFERENCE"
            echo "Checksums: $CONTENT_CSUM (configuration), $SERVER_CSUM ($SERVER)"
            echo ""
            exit 1
          fi
        fi
      else
        just display-error "Unable to compute checksum for file: $CONFIGFILE"
        exit 1
      fi
    else
      just display-error "Unable to locate file on server: $CONFIGFILE"
      exit 1
    fi
  fi

  exit 0

[linux]
[no-cd]
[private]
is-file-ignored $FILE:
  #!/usr/bin/env bash

  set -euo pipefail

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^# ]] && continue
    [ -z "$line" ] && continue

    # Remove leading/trailing whitespace
    line=$(echo "$line" | tr -d '[:space:]')

    # Skip exception patterns
    if [[ "$line" =~ ^! ]]; then
        continue
    fi

    # Convert pattern to regex
    # Handles: * (any number of characters), ? (single character), [a-z] (character classes)
    regex=$(echo "$line" | sed -E 's/\*\/\./\.\*\/\./g; s/\*\.*/\.\*\.txt/g; s/\?/./g; s/[\[\/\]]/\\&/g')

    # Check if file matches pattern (case-sensitive)
    if [[ "$FILE" =~ $regex ]]; then
        exit 0
    fi
  done < ".diffignore"

  exit 1

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

# Preprocess all servers (templates + static files) and transpile fragments into Ignition JSON
[linux]
[no-cd]
[private]
preprocess-templates:
  #!/usr/bin/env bash
  set -euo pipefail

  rm -rf .staging
  mkdir -p .staging

  echo "==> Running bulk preprocessing for all servers..."
  python3 scripts/preprocess.py servers/ templates/ .staging/ files/

  echo "==> Transpiling preprocessed .bu fragments into .ign files..."
  find .staging -name "*.bu" | while read -r bu_file; do
    ign_file="${bu_file%.bu}.ign"
    # Pass the staging directory for ther server as the files-dir (-d) so relative paths resolve
    server_staging_dir=$(dirname "$bu_file")
    butane --strict -d "$server_staging_dir" "$bu_file" > "$ign_file"
  done

  echo "Success! All server staging directories prepared and transpiled."

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
