# Helper for build recipe.
[linux]
[private]
build-ignition $FILE FILES_DIR='.':
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Set up file path for Ignition file.
  # Path should match the Butane file unless it is `main.bu`. In that case, the
  # Ignition file should be named after the parent folder name which represents
  # the server.
  IGNITION_FILE="{{ justfile_directory() }}/.generated/${FILE%.*}.ign"
  if [ "$(basename $FILE)" == "main.bu" ]; then
    IGNITION_FILE="${IGNITION_FILE%/*}.ign"
  fi
  mkdir -p "$(dirname $IGNITION_FILE)"

  # Generate Ignition file.
  echo "Generating ignition file: $IGNITION_FILE"
  podman run --rm -i -v "{{ justfile_directory() }}":/files:z,rw,rslave,rbind --workdir /files quay.io/coreos/butane:release \
    --pretty --files-dir "{{ FILES_DIR }}" < "${FILE}" > "$IGNITION_FILE"

[linux]
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
        echo "Content missing from file: $CONFIGFILE"
        echo "Content:"
        echo "${MISSING_CONTENT[@]}"
        exit 1
      fi
    else
      echo "Unable to locate file on server: $CONFIGFILE"
      exit 1
    fi
  fi

  exit 0

[linux]
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
          echo "Content differs for file: $CONFIGFILE"
          if ! DIFFERENCE=$(ssh $SERVER "echo \"$CONTENT\" | sudo diff - \"$CONFIGFILE\""); then
            echo "$DIFFERENCE"
            echo "Checksums: $CONTENT_CSUM (configuration), $SERVER_CSUM ($SERVER)"
            echo ""
            exit 1
          fi
        fi
      else
        echo "Unable to compute checksum for file: $CONFIGFILE"
        exit 1
      fi
    else
      echo "Unable to locate file on server: $CONFIGFILE"
      exit 1
    fi
  fi

  exit 0

[linux]
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

# Helper for validate recipe.
[linux]
[private]
validate-ignition $FILE:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Validate Ignition file.
  echo "Validating ignition file: $FILE"
  podman run --rm -i quay.io/coreos/ignition-validate:release - < "$FILE"

# Transpiles butane configuration(s) to create ignition file(s)
[linux]
build:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/butane:release > /dev/null

  # Find butane files and sort them in reverse order. The `main.bu` file is excluded
  # in the first search to ensure it is added last for each server.
  shopt -s globstar
  readarray -t BUTANE_FILES < <(ls -1 config/**/*.bu | grep -v main.bu | sort -r)
  BUTANE_FILES+=($(ls -1 config/**/main.bu | sort -r))

  # Transpile each Butane file and create an Ignition file.
  for FILE in ${BUTANE_FILES[@]}; do
    if [ "$(basename $FILE)" != "main.bu" ]; then
      just build-ignition "$FILE"
    else
      just build-ignition "$FILE" ".generated"
    fi
  done

# Remove all rendered ignition files.
[linux]
clean:
  @rm -rf .generated

# Creates archives for configurations
[linux]
create-archives *config:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Create directory for archives
  pushd "{{ justfile_directory() }}" &>/dev/null
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

  popd &>/dev/null

[linux]
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
        echo "Unable to process file: $CONFIGFILE"
        EQUAL="false"
      fi
    done
  done

  # Disable globstar
  shopt -u globstar

  # Exit unsuccessfully if not equal
  if [ "$EQUAL" != "true" ]; then
    echo "Configuration drift has been detected."
    exit 1
  fi

# Download latest stable Fedora CoreOS ISO
[linux]
download-iso:
  @podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data quay.io/coreos/coreos-installer:release download -f iso

# Extract archives for configurations
[linux]
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

# Output compatible Butane configuration for each specified file
[linux]
generate *files:
  #!/usr/bin/env bash

  set -euo pipefail

  echo "NOT IMPLEMENTED"
  exit 1

# [REFACTOR] Lint butane files using own container.
[linux]
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

  # Find all Butane files and lint them as if they were YAML files.
  shopt -s globstar
  for FILE in config/**/*.bu; do
    echo "Linting butane file: $FILE"
    if [ $HAS_YAMLLINT -ne 0 ]; then
      podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "$FILE"
    else
      pushd "{{ justfile_directory() }}" &>/dev/null
      yamllint "$FILE"
      popd &>/dev/null
    fi
  done

# Hosts the ignition files for deployment
[linux]
serve:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Spin up a Python HTTP server to serve the Ignition files.
  pushd "{{ justfile_directory() }}/.generated" &> /dev/null
  python3 -m http.server

# Configures WSL2 environment for development.
[linux]
setup:
  #!/usr/bin/env bash

  set -euo pipefail

  if just is-wsl-environment && just is-ubuntu; then
    # Update package cache
    sudo apt update

    # Update existing packages
    sudo apt upgrade -y

    # Install podman packages if needed.
    if ! which podman &>/dev/null; then
      sudo apt install -y podman podman-docker
    else
      echo "INFO: Located podman. Skipping installation..."
    fi

    # Install python packages if needed.
    if ! which python3 &>/dev/null; then
      sudo apt install -y python3 python3-pip
    else
      echo "INFO: Located python. Skipping installation..."
    fi
  else
    echo "ERROR: The setup recipe only works for WSL2-based Ubuntu distributions."
    exit 1
  fi

# Validate generated ignition files
[linux]
validate:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/ignition-validate:release > /dev/null

  # Validate all generated Ignition files.
  if [ -d "{{ justfile_directory() }}/.generated/config" ]; then
    shopt -s globstar
    for FILE in {{ justfile_directory() }}/.generated/**/*.ign; do
      just validate-ignition "$FILE"
    done
  else
    echo "ERROR: Unable to locate ignition files directory."
    exit 1
  fi
