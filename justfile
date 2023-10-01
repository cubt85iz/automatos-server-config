set ignore-comments := true

# Remove all rendered templates and ignition files (excluding secrets.yml).
clean:
  git clean -x -d -f -e secrets.yml

# Renders jinja templates to produce butane configurations
configure:
  just clean

# Transpiles butane configurations to create an ignition file
build:
  test -f config.bu || just configure
  butane -o config.ign config.bu

# Hosts the ignition file for deployment
serve:
  test -f config.ign || just build
  python -m http.server