set ignore-comments := true
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# Helper for build recipe.
[linux]
[private]
build-ignition $FILE FILES_DIR='.':
  #!/usr/bin/env bash

  set -euo pipefail

  IGNITION_FILE=".generated/${FILE%.*}.ign"
  mkdir -p "$(dirname $IGNITION_FILE)"

  podman run --rm -i -v .:/files:z,rw,rslave,rbind --workdir /files quay.io/coreos/butane:release \
    --pretty --files-dir "{{ FILES_DIR }}" < "${FILE}" > "$IGNITION_FILE"

  echo "Generated ignition file: $IGNITION_FILE"

# Helper for validate recipe.
[linux]
[private]
validate-ignition $FILE:
  #!/usr/bin/env bash

  set -euo pipefail

  podman run --rm -i quay.io/coreos/ignition-validate:release - < "$FILE"

# Transpiles butane configuration(s) to create ignition file(s)
[linux]
build:
  #!/usr/bin/env bash

  set -euo pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/butane:release > /dev/null

  # Create stack of butane files for processing. Otherwise, files
  # will be processed in the incorrect order, causing errors.
  shopt -s globstar
  CONFIG_STACK=()
  for FILE in config/**/*.bu; do
    CONFIG_STACK=("$FILE" "${CONFIG_STACK[@]}")
  done

  # Build configurations in the stack
  for FILE in ${CONFIG_STACK[@]}; do
    if [ "$(dirname $FILE)" != "config" ]; then
      just build-ignition "$FILE"
    else
      just build-ignition "$FILE" ".generated"
    fi
  done

# Transpiles butane configuration(s) to create ignition file(s)
[windows]
build:
  ./scripts/build.ps1

# Remove all rendered ignition files.
clean:
  rm -rf .generated

# Creates archives for configurations
[linux]
create-archives *config:
  #!/usr/bin/env bash

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
download-iso:
  podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data quay.io/coreos/coreos-installer:release download -f iso

# Extract archives for configurations
[linux]
extract-archives *config:
  #!/usr/bin/env bash

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

  set -euo pipefail

  podman pull -q docker.io/pipelinecomponents/yamllint:latest > /dev/null

  shopt -s globstar
  for FILE in config/**/*.bu; do
    podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "$FILE"
    echo "Linted butane file: $FILE"
  done

# Hosts the ignition files for deployment
[linux]
serve:
  #!/usr/bin/env bash

  set -euo pipefail

  # Source bash aliases
  if [ -f $HOME/.bash_aliases ]; then
    . $HOME/.bash_aliases
  fi

  pushd .generated &> /dev/null
  test -f *.ign || just build
  python3 -m http.server

# Hosts the ignition file for deployment
[windows]
serve:
  ./scripts/serve.ps1

# Validate generated ignition files
[linux]
validate:
  #!/usr/bin/env bash

  set -euo pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/ignition-validate:release > /dev/null

  if [ -d ".generated/config" ]; then
    shopt -s globstar
    for FILE in .generated/**/*.ign; do
      just validate-ignition "$FILE"
    done
  else
    echo "ERROR: Unable to locate ignition files directory."
    exit 1
  fi
