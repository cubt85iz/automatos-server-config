set ignore-comments := true

# Install python package dependencies.
install-deps:
  python3 -m pip install -r requirements.txt

# Remove all rendered templates and ignition files (excluding secrets.yml).
clean:
  git clean -x -d -f -e secrets.yml

# Renders jinja templates to produce butane configurations
configure: clean
  #!/usr/bin/env bash
  shopt -s globstar
  for file in **/*.j2; do ./render_template.py ${file#templates/} "secrets.yml"; done

# Transpiles butane configurations to create an ignition file
build:
  just install-deps
  test -f config.bu || just configure
  butane -d . -o config.ign config.bu

# Hosts the ignition file for deployment
serve:
  test -f config.ign || just build
  python3 -m http.server
