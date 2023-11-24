# OSN (OS for NAS)

This project uses Jinja2 templates to define a butane configuration that can be transpiled to create an ignition file for Fedora CoreOS installations. The generated ignition file configures the host environment for [osn](https://github.com/cubt85iz/osn.git) images.

## Project Structure

### `templates`

This folder contains the Jinja2 templates for the butane configuration. The `config.bu.j2` file contains the primary configuration. Additional templates for hosted services can be found in the `etc/containers/systemd` folder. The `path.mount.j2` file is a template for creating mountpoints specified in the `mounts` section of the `secrets.yml` file.

### `justfile`

The `justfile` contains recipes for making it easier to build & deploy the project. The `download-iso` recipe will download the latest stable x86_64 release for Fedora CoreOS. The `configure` recipe references a python script that renders the Jinja2 templates. The rendered butane configuration will contain secrets and is therefore included in the `.gitignore` file. The `build` recipe will build the ignition file from the provided butane configuration files. The `serve` recipe will start up a web server to allow installations to access the generated _config.ign_ file.

## Instructions

1. Update the `config.bu.j2` template to include any changes to the butane configuration.
1. Define secrets in the `secrets.yml` file. Use the `secrets.yml.md` file as an example.
1. Execute `just download-iso` to download the latest Fedora CoreOS ISO file. Write the ISO to a USB drive using Etcher (or similar tool)
1. Execute `just serve` to configure, build and serve the ignition file.
1. Boot into Fedora CoreOS live distribution.
1. Execute `sudo coreos-installer install --insecure-ignition --ignition-url http://<web-server-ip>/.generated/config.ign <disk-device>`. Example: `sudo coreos-installer install --insecure-ignition --ignition-url http://192.168.1.100/.generated/config.ign /dev/nvme0n1`.
1. Execute `poweroff`, unplug the USB drive, and power on the machine again. Follow the instructions for [osn](https://github.com/cubt85iz/osn.git) to rebase to new image.
