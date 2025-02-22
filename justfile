set ignore-comments := true
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

[linux]
[private]
build-ignition $FILE FILES_DIR='.':
  #!/usr/bin/env bash

  set -euox pipefail

  mkdir -p ".generated/${FILE%/*}"

  butane -p -d "{{FILES_DIR}}" -o ".generated/${FILE%.*}.ign" "${FILE}"

[linux]
[private]
validate-ignition $FILE:
  #!/usr/bin/env bash

  set -euox pipefail

  podman run --rm --pull=always -i quay.io/coreos/ignition-validate:release - < "$FILE"

# Transpiles butane configuration(s) to create ignition file(s)
[linux]
build:
  #!/usr/bin/env bash

  set -euox pipefail

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

  shopt -s globstar
  for FILE in config/**/*.bu; do
    podman run --rm docker.io/pipelinecomponents/yamllint:latest yamllint "$FILE"
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

  set -euox pipefail

  pushd config &> /dev/null
  test -f *.ign || (echo "ERROR: No ignition files found." && exit 1)
  for FILE in config/*.bu; do
    just build-ignition "$FILE" ".generated"
  done
