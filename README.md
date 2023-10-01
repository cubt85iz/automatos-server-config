# OSN (OS for NAS)

This project uses Jinja2 templates to define a butane configuration that can be transpiled to create an ignition file for Fedora CoreOS installations.

## Project Structure

### `keys`

This folder contains the public keys for SSH connections.

### `templates`

This folder contains the Jinja2 templates for the butane configuration. The `config.bu.j2` file contains the primary configuration. Additional templates for hosted services can be found in the `services` folder. The `units` folder contains the Jinja2 templates for the systemd unit files that are associated with the configuration.

### `justfile`

The `justfile` contains recipes for making it easier to build & deploy the project. The `configure` recipe references a python script that renders the Jinja2 templates. The rendered butane configuration will contain secrets and is therefore included in the `.gitignore` file. The `build` recipe will build the ignition file from the provided butane configuration files. The `serve` recipe will start up a web server to allow installations to access the generated _config.ign_ file.

## Instructions

1. Create butane configurations & systemd unit files for hosted services.
1. Update the _config.bu.j2_ template to include your added butane configurations.
1. If necessary, add butane configurations to the .gitignore file.
1. Execute `just serve` to configure, build and serve the ignition file.
1. Follow the Fedora CoreOS Installation instructions to apply the hosted configuration.
