# Automatos Server Configuration Format

This document describes the structure and schema of the configuration files used to define an Automatos server instance. These files (typically named `secrets.yaml`) are written in YAML and represent the complete desired state of a server, including its networking, security, containerized services, storage, and user management.

## Top-Level Structure

The root of the document contains a `configuration` object, which is subdivided into several functional domains.

---

## 1. Configuration Domains

### `firewall`
Defines the network access control policy.

* **`services`**: A registry of available services.
    * `name`: Internal identifier used by zones.
    * `display_name`: Human-readable name.
    * `description`: Brief explanation of the service.
    * `port`: The network port the service listens on.
* **`zones`**: Logical network groupings (e.g., `public`).
    * `services`: A list of service names (from the registry above) allowed within this zone.

### `networking`
Defines the physical and logical network interfaces.

* **`interfaces`**: Physical network adapters (e.g., `eth0`) and their MAC addresses.
* **`vlans`**: Virtual LAN definitions, mapping a name to a subnet pattern (e.g., `192.168.84.*`).

### `security`
Contains identity and access management settings.

* **`ssh_host_keys`**: A list of SSH host keys to be installed on the server.
    * `type`: The key algorithm (e.g., `ecdsa`, `ed25519`, `rsa`).
    * `private`: The private key content.
    * `public`: The corresponding public key.

### `services`
Manages the lifecycle and runtime configuration of containerized applications.

* **`containers`**: Definitions for individual containerized services.
    * `name`: Unique identifier for the service.
    * `auto_update`: Update policy (e.g., `registry`).
    * `command`: The startup command or arguments passed to the container.
    * `dependencies`:
        * `after`: A list of services that must start before this one.
        * `requires`: A list of services this service depends on.
    * `devices`: Hardware pass-through configuration (e.g., `nvidia.com/gpu=all`).
    * `security`: Container isolation settings:
        * `user_ns`: User namespace configuration (e.g., `auto`).
        * `user`: UID/GID mapping for the container process.
        * `drop_capability`: List of Linux capabilities to remove for hardening.
        * `no_new_privileges`: Boolean to prevent the process from gaining new privileges.
        * `pids_limit`: Maximum number of processes allowed.
    * `variables`:
        * `container`: Environment variables available to the container runtime.
        * `service`: Environment variables passed specifically to the application.
* **`networks`**: Virtual networks for container communication.
    * `name`: Network identifier.
    * `subnet`: The CIDR block for the network.
    * `containers`: A list of container names to attach to this network.

### `storage`
Defines the filesystem, files, and storage pools.

* **`directories`**: Root directories to be provisioned with specific ownership (`user`/`group`).
* **`files`**: Specific files to be created.
    * `path`: Target filesystem path.
    * `contents`: The file content.
    * `user`/`group`: File ownership.
    * `mode`: Filesystem permissions (e.g., `0644`).
* **`links`**: Symbolic links to be created (`path` -> `target`).
* **`pools`**: Storage pools and their respective `mountpoint`.

### `users`
Defines system-level user accounts.

* `name`: The username.
* `password_hash`: The hashed password for authentication.
* `ssh_authorized_keys`: A list of public SSH keys allowed for this user.

### `variables`
A collection of global key-value pairs available to the entire configuration context.

---

## Schema Summary Table

| Section | Purpose | Key Components |
| :--- | :--- | :--- |
| `firewall` | Access Control | Services, Zones |
| `networking` | Connectivity | Interfaces, VLANs |
| `security` | Identity | SSH Host Keys |
| `services` | Workloads | Containers, Networks |
| `storage` | Filesystem | Directories, Files, Links, Pools |
| `users` | Authentication | Users, SSH Keys |
| `variables` | Global State | Key-Value pairs |
