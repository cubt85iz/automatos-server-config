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
  IGNITION_FILE=".generated/${FILE%.*}.ign"
  if [ "$(basename $FILE)" == "main.bu" ]; then
    IGNITION_FILE="${IGNITION_FILE%/*}.ign"
  fi
  mkdir -p "$(dirname $IGNITION_FILE)"

  # Generate Ignition file.
  echo "Generating ignition file: $IGNITION_FILE"
  podman run --rm -i -v .:/files:z,rw,rslave,rbind --workdir /files quay.io/coreos/butane:release \
    --pretty --files-dir "{{ FILES_DIR }}" < "${FILE}" > "$IGNITION_FILE"

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
    readarray -t ARCHIVES < <(ls -1 config/.archives/*.tar)
  else
    read -a ARCHIVES <<< "{{ config }}"
    ARCHIVES=(${ARCHIVES[@]/#/config\/.archives\/})
    ARCHIVES=(${ARCHIVES[@]/%/.tar})
  fi

  # Iterate over array and extract archives.
  for ARCHIVE in "${ARCHIVES[@]}"; do
    tar xf "$ARCHIVE"
    echo "Extracted archive: $ARCHIVE"
  done

# [REFACTOR] Lint butane files using own container.
[linux]
lint:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  podman pull -q docker.io/pipelinecomponents/yamllint:latest > /dev/null

  # Find all Butane files and lint them as if they were YAML files.
  shopt -s globstar
  for FILE in config/**/*.bu; do
    echo "Linting butane file: $FILE"
    podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "$FILE"
  done

# Hosts the ignition files for deployment
[linux]
serve:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Spin up a Python HTTP server to serve the Ignition files.
  pushd .generated &> /dev/null
  python3 -m http.server

# Validate generated ignition files
[linux]
validate:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/ignition-validate:release > /dev/null

  # Validate all generated Ignition files.
  if [ -d ".generated/config" ]; then
    shopt -s globstar
    for FILE in .generated/**/*.ign; do
      just validate-ignition "$FILE"
    done
  else
    echo "ERROR: Unable to locate ignition files directory."
    exit 1
  fi
