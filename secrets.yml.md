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

### Audiobookshelf

```yaml
audiobookshelf_gid: 1000
audiobookshelf_uid: 1000
```

## Mount configuration

```yaml
mounts:
  - path: /mnt/container/container-data
    target: /tank/container/container-data
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
