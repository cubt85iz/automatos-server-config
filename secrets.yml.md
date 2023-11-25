# Example Secrets File

## Host configuration

```yaml
hostname: myserver
domain: home.example.com
timezone: 'Etc/UTC'
```

## User configuration

```yaml
users:
  - name: core
    password: '<password-hash>'
    pubkeys:
      - 'ssh-ed25519 <hash>'
```

## Container secrets

Secrets for .env templates. Generated .env files will contain the secrets specified here.

### Audiobookshelf

```yaml
audiobookshelf_gid: 1000
audiobookshelf_uid: 1000
```

## Additional Directories

Additional directories to add to the generated ignition file (ex. ZFS pool mountpoint)

```yaml
addl_directories:
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
