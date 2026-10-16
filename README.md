# Fedora CoreOS Infrastructure Blueprint

Declarative, reproducible, and secure homelab infrastructure managed via **Fedora CoreOS**, **Butane/Ignition**, **Jinja2 templates**, **Mozilla SOPS**, and orchestrated locally using `just`.

---

## 🚀 Project Objectives

* **Declarative Infrastructure:** Define the entire operating system state, storage layout, networking, and container topology as code.
* **Modularity & Reusability:** Separate core system blueprints (`templates/`) from server-specific states (`servers/`) to eliminate configuration duplication.
* **Zero-Knowledge Secrets Management:** Encrypt sensitive credentials (API keys, private SSH host keys, backup passphrases) using **Mozilla SOPS**, **Age**, and **Bitwarden**.
* **Immutable Automation:** Compile, validate, and build Ignition provisioning files locally using automated task workflows.

---

## 📁 Repository Structure

```text
.
├── files/          # Global static files, systemd units, and scripts
├── schemas/        # Schema files (secrets.schema.json & secrets.schema.md)
├── scripts/        # Automation tooling (preprocessing templates, encrypting secrets)
├── servers/        # Node-specific configurations and encrypted secrets
├── templates/      # Modular Jinja2/Butane blueprint fragments
├── justfile        # Task runner definitions for building and validation
└── README.md       # Project documentation

```

* `files/`: Contains raw, static files (scripts, configurations) that do not require templating and are copied into staging during builds.
* `schemas/`: Houses specification documentation, including [`schemas/secrets.schema.md`](schemas/secrets.schema.md) (the human-readable spec) and `secrets.schema.json` (the programmatic validation schema), detailing data types and structures for server configurations.
* `scripts/`: Automation helper scripts, including `preprocess.py` (which merges secrets with templates) and `encrypt_secrets.py` (for SOPS).
* `servers/`: Node-specific inventories (e.g., `servers/prometheus/`). Each server contains its own primary `main.bu` manifest and encrypted `secrets.enc.yaml`.
* `templates/`: Modular `.bu` and `.j2` template fragments organized by concern (firewall, networking, security, storage, container services).

---

## 🏛️ Architectural Overview

### 1. Fedora CoreOS (FCOS)

Fedora CoreOS is an automatically updating, minimal, container-focused operating system designed for running containerized workloads securely at scale. The root filesystem is immutable, meaning all system configuration, user accounts, and container deployment definitions must be provisioned during first boot.

### 2. Butane & Ignition

* **Butane:** A human-friendly YAML-based syntax wrapper designed to prevent manual errors in low-level JSON configuration files.
* **Ignition:** The provisioning utility read by FCOS on its first boot. Ignition configures disks, creates system users, sets up ssh keys, writes files, and provisions systemd/Podman Quadlet units.

### 3. Mozilla SOPS, Age & Bitwarden

* **Age:** A modern, secure file encryption tool supporting post-quantum primitives (ML-KEM-768 + X25519).
* **Mozilla SOPS:** Integrates with Age to encrypt individual values within YAML files while leaving structure and keys readable.
* **Bitwarden CLI:** Used as a secure remote backend to store and retrieve generated post-quantum Age key pairs for server environments.

---

## 🛠️ Just Recipes & Functions

`just` is a modern command runner (a clean, language-agnostic alternative to `make`) used to execute project workflows defined in the `justfile`.

### Build & Provisioning

* `just run`: Executes the full lifecycle pipeline (`clean` $\rightarrow$ `lint` $\rightarrow$ `build` $\rightarrow$ `validate` $\rightarrow$ `serve`) and automatically cleans up on exit.
* `just build`: Preprocesses templates, stages static assets, transpiles fragments into `.ign` files concurrently, and compiles each server's primary `main.bu` manifest into its final deployment Ignition configuration.
* `just validate`: Validates all generated Ignition JSON files using the official CoreOS validation container.
* `just serve`: Spins up a local Python HTTP server inside `.generated/` to host and serve the compiled Ignition files for server deployment.

### Secrets & Key Management

* `just generate-age-key <folder>`: Generates a post-quantum Age key pair and securely stores it in Bitwarden.
* `just rotate-age-key <folder>`: Rotates an existing server's age key pair with a new post-quantum pair and updates Bitwarden.
* `just encrypt-secrets <folder>`: Encrypts a server's local plaintext `secrets.yaml` into `secrets.enc.yaml` using its associated public Age key from Bitwarden.
* `just decrypt-secrets <folder>`: Decrypts a server's `secrets.enc.yaml` back into `secrets.yaml` using the private Age key retrieved from Bitwarden.

### Verification & Diagnostics

* `just validate-secrets`: Validates all plaintext secrets.yaml files against the defined JSON schema rules.
* `just lint`: Runs `yamllint` locally or via container across all preprocessed Butane fragments.
* `just diff <server>`: Compares the declared configuration state against a running live server to detect configuration drift.

### Maintenance & Utility

* `just update`: Pulls and updates submodules to their latest remote versions.
* `just clean`: Removes all local build and staging directories (`.generated`, `.staging`).
* `just download-iso`: Downloads the latest stable Fedora CoreOS live ISO using the official coreos-installer.
* `just provision-toolbox`: Rebuilds the custom OCI builder image and recreates the local Toolbx container (`fcos-builder`).
* `just setup`: Bootstraps the development environment packages (Butane, Podman, YAMLLint, Python) on Ubuntu/WSL2 distributions.
* `just create-archives` / `just extract-archives`: Compresses or extracts configuration tarball archives.

---

## ⚙️ How to Add a New Server

To spin up a new Fedora CoreOS node using this repository:

1. **Create a Server Directory:**
Create a new folder under `servers/` matching your host's name:
```bash
mkdir -p servers/my-new-node/files

```


2. **Define Your Secrets:**
Create a `servers/my-new-node/secrets.yaml` file containing your node-specific variables under the `configuration` root block (refer to the [Secrets Specification Schema Guide](schemas/secrets.schema.md) for field details).
Validate your file against the schema:
```bash
just validate-secrets

```


3. **Create the Primary Manifest (`main.bu`):**
Create a `servers/my-new-node/main.bu` file that uses Ignition configuration merging to pull in the modular fragments generated from your templates:
```yaml
variant: fcos
version: 1.6.0

ignition:
  config:
    merge:
      - local: security/users.ign
      - local: ssh/host-keys.ign
      # ... include other required fragments ...

```


4. **Build the Ignition Configuration:**
Run the build pipeline via `just`:
```bash
just run

```


Your compiled, deployment-ready Ignition file will be served on port 8000 `http://localhost:8000/my-new-node.ign`.


5. **Deploy to a Server:**
Deploy to a server using `coreos-installer`:
```bash
sudo coreos-installer install /dev/sda --ignition-url http://my-host-pc:8000/my-new-node.ign --insecure-ignition
```
