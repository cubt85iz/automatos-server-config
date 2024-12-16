# automatos-server

Toolkit for declarative configuration of a Fedora CoreOS server.

## Project Structure

This project will allow users to serve custom Ignition-compatible configurations that can be used to seed a Fedora CoreOS installation. To do this, it uses the configuration specified in `secrets.yml` and transforms it into a format that is compatible with the Butane 1.5.0 specification.

### Configuration Settings / Secrets

All configuration settings and secrets are defined in the `secrets.yml` file. For more details, see specification section below.

### Templates

Jinja2 templates are included in the `templates` folder.

| **Template** | **Description** |
|:--|:--|
| etc/systemd/system/backup.target.j2 | Creates systemd target unit (`backup.target`) that contains a timer for each container that has a backup configuration specified. |
| etc/systemd/system/healthcheck-container.target.j2 | Creates systemd target unit (`healthcheck-container.target`) that contains a timer for each container that has a monitoring URL. |
| etc/systemd/system/sync.target.j2 | Creates a systemd target unit (`sync.target`) that contains a timer for each synchronization job that has been specified. |
| etc/environment.j2 | Creates the `/etc/environment` file containing the variables specified for the host. |
| config.bu.j2 | Creates the `config.bu` file containing the Butane 1.5.0 compatible configuration. |
| container-backup.conf.j2 | Creates the drop-ins for container services that contain the necessary environment variables for creating backups. |
| container-config.env.j2 | **[DEPRECATED]** Creates the environment files for containers in the `/etc/containers/config` folder. |
| firewalld.xml.j2 | Creates the firewalld configuration files in the `/etc/firewalld/zones` folder. |
| network.nmconnection.j2 | Creates the network configuration files in the `/etc/NetworkManager/system-connections` folder. |
| path.mount.j2 | Creates systemd mount units in the `/etc/systemd/system` folder. |
| rclone.conf.j2 | Creates the `/etc/rclone/rclone.conf` configuration file. |
| smb.conf.j2 | Creates the `/etc/samba/smb.conf` configuration file. |
| sync.env.j2 | Creates environment files in `/etc/` that contain the settings for each synchronization job. |

### `justfile`

The `justfile` contains recipes for making it easier to build & deploy the project.

|**Recipe** | **Description** |
|:--|:--|
| build | Uses `butane` to transpile configuration into an ignition file. |
| clean | Removes all rendered templates, Ignition files and untracked files. |
| configure | Renders Jinja2 templates to produce files and Butane-compatible configuration. |
| download-iso | Downloads the latest stable Fedora CoreOS ISO. |
| install-deps | Installs python package dependencies. |
| serve | Spins up a web server to host the generated Ignition file. |

## Specification

This specification extends the Fedora CoreOS Butane Configuration Specification to add additional functionality. It produces a Butane configuration that can be transpiled to create an Ignition file for Fedora CoreOS installations.

* **hostname** _(string)_

  Hostname for the computer. Value is combined with `domain` and written to `/etc/hostname`.

* **domain** _(string)_

  Domain for the computer. Value is combined with `hostname` and written to `/etc/hostname`.

* **timezone** _(string)_

  String representing a [time zone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List) (ex. `America/New_York`)

* **containers** _(object[])_

  List of container objects. The values provided will be used to configure containers.

  * **name** _(string)_
  
    Name of the container. The value provided will be used for the name of the container's environment file stored in `/etc/containers/config/`.

  * **path** _(string)_

    Path to the container's volumes, `CONTAINER_PATH`. This variable is referenced by the container quadlets for bind-mounting volumes.

  * **dataset** _(string)_
  
    The ZFS dataset containing container volumes. This dataset will have a snapshot taken prior to each backup.

  * **monitor_url** _(string)_
  
    The URL for the healthchecks.io healthcheck responsible for monitoring container health.

  * **backup** _(object)_

    Backup job for container files.

    * **path** _(string)_

      Path to store backup files.

    * **monitor_url** _(string)_

      The URL for the healthchecks.io healthcheck responsible for monitoring backup health.

    * **remotes** _(string[])_

      The list of Rclone remotes to utilize when synchronizing backup files. These are defined in `/etc/rclone.conf`. The remotes listed here should match those specified in the `rclone` section below.

    * **keep_daily** _(integer)_

      Number of daily backups to keep.

    * **keep_weekly** _(integer)_

      Number of weekly backups to keep.

    * **keep_monthly** _(integer)_

      Number of monthly backups to keep.

    * **keep_yearly** _(integer)_

      Number of yearly backups to keep.

  * **[DEPRECATED] variables** _(string[])_
  
    List of environment variables for container. Variables should be specified in `KEY=VALUE` format so they can be sourced by systemd unit files.

  * **overrides** _(object[])_

    Overrides for podman.unit drop-in files.
 
    | :memo: **NOTE** |
    | -- |
    | Some container options do not work (ex. `AddHost`). When a container option doesn't work the service is not loaded by systemd. Unsure of what other options do not work, but `Environment` and `Volume` appear to work. |

    * **file** (_(string)_)

      Name for drop-in file.

    * **options** (_(object[])_)

      List of options for drop-in file.

      * **key** (_string_)

        Container option for drop-in file.

      * **value** (_string_)

        Value for Container option

      * **section** (_string_)

        Section of unit file for option

  Example:

  ```yaml
  containers:
    - name: mealie
      path: /var/pool/volumes/mealie
      dataset: pool/volumes/mealie
      backup:
        path: /my/borg/repo/mealie
        remotes:
          - backblaze
        keep_daily: 7
        keep_weekly: 4
        keep_monthly: 2
        keep_yearly: 0
      overrides:
        - file: 10-mealie-variables.conf
          options:
            - key: Environment
              value: "PGID=1000"
            - key: Environment
              value: "PUID=1000"
            - key: Environment
              value: "TZ=America/New_York"
            - key: Environment
              value: "PORT=8080"
              section: Service
  ```

* **directories** _(string[])_

  List of additional directories to create. The paths specified should be absolute.

  Example:

  ```yaml
  directories:
    - /var/pool
  ```

* **disks** _(string[])_

  List of disk devices to use in a mirrored pool for root. _(NOTE: This doesn't appear to function properly.)_

  Example:

  ```yaml
  disks:
    - /dev/disk/by-id/unique-name-disk-1
    - /dev/disk/by-id/unique-name-disk-2
  ```

* **environment** _(string[])_

  List of environment variables. Variables should be specified in `KEY=VALUE` pair format so they can be sourced by systemd unit files. The variables listed here will be written to `/etc/environment`.
  
  The variables `BACKUP_KEY`, `SHARED_VOLUMES_PATH`, `UPDATES_MONITOR_URL`, & `ZFS_MONITOR_URL` are utilized by systemd unit files. They must exist for dependent services to execute.

  The variable `BACKUP_KEY` represents the passphrase used for encrypting files during the backup process. The `SHARED_VOLUMES_PATH` variable represents the path to the location of files that are shared across containers. The `UPDATES_MONITOR_URL` represents the healthchecks.io URL that will be triggered when important security updates are available. The `ZFS_MONITOR_URL` represents the healthchecks.io URL that will be triggered when any ZFS pool is unhealthy.

  Example:

  ```yaml
  environment:
    - "BACKUP_KEY=my-borg-passphrase"
  ```

* **firewall** _(object[])_

  List of firewall zone configurations. The values provided will be written to zone configuration files in `/etc/firewalld/zones/`.

  * **zone** _(string)_
  
    Unique name for firewall zone. This name will be used to name the XML file written to `/etc/firewalld/zones/`.

  * **services** _(string[])_
  
    List of services to enable for firewall zone. The provided services must exist.

  Example:

  ```yaml
  firewall:
    - zone: public
      services:
        - ssh
        - mdns
  ```

* **keys** _(object[])_

  SSH host keys for restoration.

  * **path** _(string)_
  
    Path to SSH host key file.

  * **content** _(string)_
  
    Content for SSH host key _(NOTE: Use literal (|) block style to preserve line breaks.)_

  * **owner** _(string)_
  
    Owner for SSH host key. This is typically `root`.

  * **group** _(string)_
  
    Group for SSH host key. This is typically `root`.

  * **mode** _(string)_

    Mode for SSH host key. This is typically `0600` for private keys and `0644` for public keys.

  Example:

  ```yaml
  keys:
    - path: /etc/ssh/ssh_host_ecdsa_key
      content: |
        -----BEGIN OPENSSH PRIVATE KEY-----
        This is my fake private key
        -----END OPENSSH PRIVATE KEY-----
      owner: root
      group: root
      mode: '0600'
  ```

* **links** _(object[])_

  List of symlinks to create.

  * **path** _(string)_
  
    Path for link

  * **target** _(string)_

    Path for link to target. This path can be relative to the link path.

  Example:

  ```yaml
  # This link will automatically be included and will utilize the value provided to timezone above. It's listed here for demonstration purposes only.

  links:
    - path: /etc/localtime
      target: /usr/share/zoneinfo/America/New_York
  ```

* **mounts** _(object[])_

  List of devices to mount. Mount files will be created and stored in `/etc/systemd/system/` for each path specified.

  * **path** _(string)_

    Path to source path/device.

  * **target** _(string)_
  
    Path to target location.

  * **options** _(string[])_
  
    List of options to apply when mounting.

  * **before** _(string[])_
  
    List of services dependent on the mount.

  * **after** _(string[])_
  
    List of services required for the mount.

  * **description** _(string)_
  
    Description of the mount point.

  Example:

  ```yaml
  mounts:
    - path: /var/my/folder
      target: /var/mounts/binds/locationA
      options:
        - bind
      before:
        - plex.service
      after:
        - zfs-mount.service
      description: My bind mount
  ```

* **network** _(object[])_

  List of networks and their configurations. The configurations specified below will be written to `.nmconnection` files in the `/etc/NetworkManager/system-connections/` folder.

  * **interface** _(string)_
  
    Name for interface to configure.

  * **type** _(string)_
  
    Type of the interface to configure (ex. `ethernet`)

  * **settings** _(object[])_
  
    Group of settings for protocol. This is representative of a section in the `.nmconnection` file.

    * **protocol** _(string)_

      Protocol name. This will be used as the name for the section header (ex. `ipv4`).

    * **options** _(object[])_

      List of key-value pairs for protocol settings. These will be assembled into `KEY=VALUE` format for `.nmconnection` file.

      * **key** _(string)_

        Property for protocol (ex. `method`)

      * **value** _(string)_

        Value for property (ex. `auto`)

  Example:

  ```yaml
  network:
    - interface: eth0
      type: ethernet
      settings:
        - protocol: ipv4
          options:
            - key: method
              value: auto
        - protocol: ipv6
          options:
            - key: method
              value: disabled
  ```

* **rclone** _(object[])_

  List of remotes to target when synchronizing backups. To specify which remotes to use when backing up containers, see the container specification above.

  * **remote** _(string)_
  
    Unique name for remote. These values will be used for section headers in the Rclone configuration and will also be used when specifying the remotes to use when backing up containers.

  * **type** _(string)_
  
    Type for remote (ex. b2). For a full list of supported remote types, review the [Rclone Documentation](https://rclone.org/docs/).

  * **account** _(string)_
  
    Account identifier for remote.

  * **key** _(string)_
  
    Key or passphrase for remote.

  Example:

  ```yaml
  rclone:
    - remote: backblaze
      type: b2
      account: my-account-id
      key: my-account-key
  ```

* **samba** _(object[])_

  List of options that represent the Samba configuration.

  * **options** _(object[])_
  
    List of key-value pairs for configuration option.

    * **key** _(string)_

      Samba property (ex. `read only`).

    * **value** _(string)_

      Value for Samba property (ex. `no`).

  Example:

  ```yaml
  samba:
    - name: global
      options:
        - key: netbios name
          value: myserver
        - key: workgroup
          value: WORKGROUP
        - key: server string
          value: Samba %v server
        - key: security
          value: user
        - key: passdb backend
          value: tdbsam
        - key: include
          value: /etc/samba/usershares.conf
          comment: Install samba-usershares package for support
    - name: shared_docs
      options:
        - key: comment
          value: Folder for Shared Documents
        - key: path
          value: /var/my/shared/docs
        - key: read only
          value: no
        - key: browseable
          value: yes
  ```

* **sync** _(object[])_

  List of synchronization jobs. These jobs will synchronize two locations using `rsync` and the options provided below.

  * **name** _(string)_
  
    Unique name for synchronization pair. This value will be used for the template units and environment files.

  * **source** _(string)_
  
    Valid source for synchronization. This can be a path or a device.

  * **target** _(string)_
  
    Valid target for synchronization. This can be a path or a device.

  * **options** _(string[])_
  
    List of synchronization options. See [rsync(1)](https://linux.die.net/man/1/rsync) for more information about the options available for `rsync`.

  * **cooldown** _(integer)_
  
    Number of seconds to between synchronization operations. The value provided here will be used to prevent execution of the service again until the cooldown period has been exceeded.

  Example:

  ```yaml
  sync:
    name: music-usb
    source: /path/to/music
    target: /path/to/usb/device
    options:
      - '-vrht'
      - '--modify-window=1'
      - '--exclude=Michael[[:space:]]Jackson'
      - '--delete'
      - '--delete-excluded'
  ```

* **users** _(object[])_

  List of user accounts.

  * **name** _(string)_
  
    Unique name for user

  * **password** _(string)_
  
    Hashed password for user account (See [mkpasswd(1)](https://linux.die.net/man/1/mkpasswd)).

  * **pubkeys** _(string[])_
  
    List of public keys to write to ~/.ssh/authorized_keys

## Instructions

1. Update the `config.bu.j2` template to include any changes to the butane configuration.
1. Define secrets in the `secrets.yml` file. Use the `secrets.yml.md` file as an example.
1. Execute `just download-iso` to download the latest Fedora CoreOS ISO file. Write the ISO to a USB drive using Etcher (or similar tool)
1. Execute `just serve` to configure, build and serve the ignition file.
1. Boot into Fedora CoreOS live distribution.
1. Execute `sudo coreos-installer install --insecure-ignition --ignition-url http://<web-server-ip>/.generated/config.ign <disk-device>`. Example: `sudo coreos-installer install --insecure-ignition --ignition-url http://192.168.1.100/.generated/config.ign /dev/nvme0n1`.
1. Execute `poweroff`, unplug the USB drive, and power on the machine again. Follow the instructions for [automatos-server](https://github.com/cubt85iz/automatos-server.git) to rebase to new image.
