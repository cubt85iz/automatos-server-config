set ignore-comments := true
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

[linux]
[private]
build-ignition $FILE FILES_DIR='.':
  #!/usr/bin/env bash

  set -euox pipefail

  mkdir -p ".generated/${FILE%/*}"

  podman run --rm -i -v .:/files:z,rw --workdir /files quay.io/coreos/butane:release \
    --pretty --files-dir "{{ FILES_DIR }}" < "${FILE}" > ".generated/${FILE%.*}.ign"
  # butane -p -d "{{FILES_DIR}}" -o ".generated/${FILE%.*}.ign" "${FILE}"

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

  set -euox pipefail

  # Pull latest ignition-validate image.
  podman pull -q quay.io/coreos/butane:release > /dev/null

  # Build dependent configurations
  for FILE in config/**/*.bu; do
    just build-ignition "$FILE"
  done

  # Build primary configurations
  for FILE in config/*.bu; do
    just build-ignition "$FILE" ".generated"
  done

# Transpiles butane configuration(s) to create ignition file(s)
[windows]
build:
  ./scripts/build.ps1

# Remove all rendered templates and ignition files (excluding secrets.yml).
clean:
  git clean -x -d -f -e config -e \*secrets\*.yml

# Download latest stable Fedora CoreOS ISO
download-iso:
  podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data quay.io/coreos/coreos-installer:release download -f iso 

# Lint butane files
[linux]
lint:
  #!/usr/bin/env bash

  set -euo pipefail

  podman pull -q docker.io/pipelinecomponents/yamllint:latest > /dev/null

  shopt -s globstar
  for FILE in config/**/*.bu; do
    podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "$FILE"
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

# Validate ignition files
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
