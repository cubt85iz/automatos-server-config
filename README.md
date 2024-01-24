# OSN (OS for NAS)

This project uses Jinja2 templates to define a butane configuration that can be transpiled to create an ignition file for Fedora CoreOS installations. The generated ignition file configures the host environment for [osn](https://github.com/cubt85iz/osn.git) images.

## Project Structure

### `templates`

This folder contains the Jinja2 templates for the butane configuration. The `config.bu.j2` file contains the primary configuration. Additional templates for hosted services can be found in the `etc/containers/systemd` folder. The `path.mount.j2` file is a template for creating mountpoints specified in the `mounts` section of the `secrets.yml` file.

### `justfile`

The `justfile` contains recipes for making it easier to build & deploy the project. The `download-iso` recipe will download the latest stable x86_64 release for Fedora CoreOS. The `configure` recipe references a python script that renders the Jinja2 templates. The rendered butane configuration will contain secrets and is therefore included in the `.gitignore` file. The `build` recipe will build the ignition file from the provided butane configuration files. The `serve` recipe will start up a web server to allow installations to access the generated _config.ign_ file.

## Specification

This specification extends the Fedora CoreOS Butane Configuration Specification to add additional functionality. It produces a Butane configuration that can be transpiled to create an Ignition file for Fedora CoreOS installations.

* **hostname** (string): Hostname for the computer. Value is combined with `domain` and written to `/etc/hostname`.
* **domain** (string): Domain for the computer. Value is combined with `hostname` and written to `/etc/hostname`.
* **timezone** (string): String representing a [time zone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List)
* **backup_key** (string): Passphrase for BorgBackup repositories.
* **healthcheck_updates_url** (string): URL for healthcheck for updates. Fails when there are important updates to install.
* **healthcheck_zfs_url** (string): URL for ZFS healthcheck. Fails when any pool is unhealthy.
* **root_disks** (string[]): List of disk devices to use in a mirrored pool for root. (**_Bugged?_**)
* **host_keys** (object[]): SSH host keys for restoration
  * **path** (string): File path to SSH host key
  * **content** (string): Content for SSH host key (NOTE: Use literal (|) block style to preserve line breaks.)
  * **owner** (string): Owner for SSH host key
  * **group** (string): Group for SSH host key
  * **mode** (string): Mode for SSH host key
* **users** (object[]): List of user accounts
  * **name** (string): Unique name for user
  * **password** (string): Hashed password for user account (See [mkpasswd(1)](https://linux.die.net/man/1/mkpasswd)).
  * **pubkeys** (string[]): List of public keys to write to ~/.ssh/authorized_keys
* **directories** (string[]): List of additional directories to create.
* **links** (object[]): List of symlinks to create.
  * **path** (string): Path for link
  * **target** (string): Path for link to target
* **mounts** (object[]): List of devices to mount.
  * **path** (string): Path to source path/device.
  * **target** (string): Path to target location.
  * **options** (string[]): List of options to apply when mounting.
  * **before** (string[]): List of services dependent on the mount.
  * **after** (string[]): List of services required for the mount.
  * **description** (string): Description for the mount
* **firewall** (object[]): List of firewall zone configurations
  * **zone** (string): Unique name for firewall zone
  * **services** (string[]): List of services to enable for firewall zone
* **rclone** (object[]): Targets for rclone transfers
  * **remote** (string): Unique name for remote
  * **type** (string): Type for remote
  * **account** (string): Account identifier for remote
  * **key** (string): Key or passphrase for remote
* **samba** (object[]): List of Samba configuration options
  * **options** (object[]): List of key-value pairs for configuration option
    * **key** (string): Key
    * **value** (string): Value
* **sync** (object[]): List of synchronization pairs for rsync
  * **name** (string): Unique name for synchronization pair
  * **source** (string): Valid source for synchronization
  * **target** (string): Valid target for synchronization
  * **options** (string[]): List of synchronization options
  * **cooldown** (integer): Number of seconds to between synchronization operations
* **containers** (object[]): List of container objects
  * **name** (string): Name for container
  * **path** (string): Path for container files
  * **backup_path** (string): Path for backup files
  * **backup_monitor_url** (string): URL for backup healthchecks
  * **monitor_url** (string): URL for container healthcheck
  * **dataset** (string): Dataset containing container volumes
  * **keep_daily** (integer): Number of daily backups to keep
  * **keep_weekly** (integer): Number of weekly backups to keep
  * **keep_monthly** (integer): Number of monthly backups to keep
  * **keep_yearly** (integer): Number of yearly backups to keep
  * **variables** (string[]): List of environment variables for container

## Instructions

1. Update the `config.bu.j2` template to include any changes to the butane configuration.
1. Define secrets in the `secrets.yml` file. Use the `secrets.yml.md` file as an example.
1. Execute `just download-iso` to download the latest Fedora CoreOS ISO file. Write the ISO to a USB drive using Etcher (or similar tool)
1. Execute `just serve` to configure, build and serve the ignition file.
1. Boot into Fedora CoreOS live distribution.
1. Execute `sudo coreos-installer install --insecure-ignition --ignition-url http://<web-server-ip>/.generated/config.ign <disk-device>`. Example: `sudo coreos-installer install --insecure-ignition --ignition-url http://192.168.1.100/.generated/config.ign /dev/nvme0n1`.
1. Execute `poweroff`, unplug the USB drive, and power on the machine again. Follow the instructions for [osn](https://github.com/cubt85iz/osn.git) to rebase to new image.
