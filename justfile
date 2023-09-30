set ignore-comments := true

# Renders jinja templates to produce butane configurations
configure:

# Transpiles butane configurations to create an ignition file
build:
  test -f config.bu || just configure
  butane -o config.ign config.bu

# Hosts the ignition file for deployment
serve:
  test -f config.ign || just build
  python -m http.server