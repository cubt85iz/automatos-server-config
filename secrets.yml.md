# Example Secrets File

## Host configuration

```yaml
hostname: myserver
domain: home.example.com
timezone: 'Etc/UTC'
```

## Host secrets

```yaml
healthcheck_updates_url: https://hc-ping.com/<uuid>
healthcheck_zfs_url: https://hc-ping.com/<uuid>
```

## User configuration

```yaml
users:
  - name: core
    password: '<password-hash>'
    pubkeys:
      - 'ssh-ed25519 <hash>'
```

## Directories

Directories to add to the generated ignition file (ex. ZFS pool mountpoint)

```yaml
directories:
  - /var/tank
```

## Links

```yaml
links:
  - path: /mnt/volume/movies/adam
    target: /var/tank/adam/Movies
  
  - path: /mnt/volume/movies/andrew
    target: /var/tank/andrew/Movies
```

## Mount configuration

```yaml
mounts:
  - path: /mnt/container/container-data
    target: /var/tank/container/container-data
    options:
      - bind
    before:
      - container.service
    description: Volume for container data

  - path: /mnt/container/container-config
    target: nfs-server:/container/container-config
    type: nfs
    before:
      - container.service
    after:
      - network-online.target
      - nss-lookup.target
    description: Volume for container configuration
```

## Samba Configuration

```yaml
samba:
  - name: global
    options:
      - key: workgroup
        value: WORKGROUP
```

## Container configuration

Secrets for .env templates. Generated .env files will contain the secrets specified here.

### Audiobookshelf

```yaml
containers:
  - name: audiobookshelf
    path: /var/containers/volumes/audiobookshelf
    monitor_url: https://hc-ping.com/<uuid>
    backup_path: /var/backups/audiobookshelf
    dataset: zfs/audiobookshelf
    keep_daily: 0
    keep_weekly: 4
    keep_monthly: 6
    keep_yearly: 0
    variables:
      - "AUDIOBOOKSHELF_GID=<gid>"
      - "AUDIOBOOKSHELF_UID=<uid>"
```
