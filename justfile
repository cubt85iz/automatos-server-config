set ignore-comments := true
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# Download latest stable Fedora CoreOS ISO
download-iso:
  podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data quay.io/coreos/coreos-installer:release download -f iso 

# Install python package dependencies.
[linux]
install-deps:
  #python3 -m pip install -r requirements.txt

# Install python package dependencies.
[windows]
install-deps:
  python -m pip install -r requirements.txt

# Remove all rendered templates and ignition files (excluding secrets.yml).
clean secretfile="secretspow.yml":
  git clean -x -d -f -e \*secrets\*.yml

# Renders jinja templates to produce butane configurations
[linux]
configure secretfile="secretspow.yml": 
  just clean {secretfile}}
  python3 configure.py {{secretfile}}

# Renders jinja templates to produce butane configurations
[windows]
configure: clean
  python configure.py

# Transpiles butane configuration to create an ignition file
[linux]
build secretfile="secretspow.yml":
  #!/usr/bin/env bash
  echo {{secretfile}} 
  set -euo pipefail

  # Source bash aliases
  if [ -f $HOME/.bash_aliases ]; then
    . $HOME/.bash_aliases
  fi

  just install-deps
  test -f config.bu || just configure {{secretfile}}
  
  # Build dependent configurations
  shopt -s globstar
  pushd .generated &> /dev/null
  for file in **/*.bu; do
    if [ "$(basename $file)" != "config.bu" ]; then
      output_file="${file%.bu}.ign"
      butane -p -d . -o "$output_file" "$file"
    fi
  done

  # Build primary configuration
  butane -p -d . -o config.ign config.bu

# Transpiles butane configuration to create an ignition file
[windows]
build:
  ./scripts/build.ps1

# Hosts the ignition file for deployment
[linux]
serve secretfile="secretspow.yml":
  #!/usr/bin/env bash

  set -euo pipefail

  # Source bash aliases
  if [ -f $HOME/.bash_aliases ]; then
    . $HOME/.bash_aliases
  fi

  pushd .generated &> /dev/null
  test -f config.ign || just build {{secretfile}}
  python3 -m http.server

# Hosts the ignition file for deployment
[windows]
serve:
  ./scripts/serve.ps1
