# Fedora CoreOS Infrastructure Blueprint

Declarative and reproducible homelab infrastructure managed via **Fedora CoreOS** and **Butane/Ignition**, orchestrated locally using `just` and `podman`.

---

## 🚀 Project Objectives

* **Declarative Infrastructure:** Define the entire operating system state, storage layout, and networking as code using Butane files.
* **Modular Profiles:** Use Butane fragments located in `servers/` to define node-specific profiles.
* **Secure Secrets Management:** Protect sensitive profile data by encrypting Butane fragments using **Mozilla SOPS** and **Age**.
* **Automated Build Pipeline:** Compile and validate Ignition provisioning files locally using parallelized `just` workflows and `podman`.

---

## 🏛️ Architectural Overview

The project follows a **Fragment-to-Provision** workflow designed for modularity and security:

1. **Profile (Input):** System state is defined in small, modular Butane fragments (`.bu`). Sensitive data is stored in encrypted fragments (`.enc.bu`) managed by **Mozilla SOPS** and **Age**, and enforced via `.sops.yaml` creation rules.
2. **Transpilation (Build):** The `just` task runner orchestrates a parallel build process. It utilizes **Podman** to run the official **Butane** container, ensuring the build environment is hermetic and consistent across different host machines.
3. **Provisioning (Output):** The resulting Ignition JSON files are served via a local **Python HTTP server**, allowing Fedora CoreOS nodes to fetch their profiles during the initial boot process.

---

## 📁 Repository Structure

```text
.
├── .just/            # Additional task definitions
│   └── shared/       # Shared output/task helpers
├── servers/          # Node-specific Butane profile fragments (.bu and .enc.bu)
├── .sops.yaml        # SOPS encryption rules and age recipient mappings per profile
├── requirements.txt  # Python dependencies
├── justfile          # Main task runner definitions
└── README.md         # Project documentation
```

* `.just/`: Contains platform-specific logic and helper modules for the `just` task runner.
* `servers/`: Contains the Butane server profiles. Standard fragments use `.bu`, while sensitive profiles are stored as encrypted `.enc.bu` files.
* `justfile`: The entry point for all automation tasks.

---

## 🛠️ Toolchain

* **[just](https://github.com/casey/just):** Command runner to execute tasks.
* **[podman](https://podman.io/):** Used to pull and run the Butane/Validation containers.
* **[Butane](https://github.com/coreos/butane):** For transpiling profiles into Ignition files.
* **[Mozilla SOPS](https://github.com/getsops/sops):** For managing encrypted secrets.
* **[Age](https://github.com/age-encryption/age):** Post-quantum encryption backend for SOPS.
* **[Bitwarden CLI](https://github.com/bitwarden/clients):** Used to securely store and retrieve encryption keys.
* **Python 3:** Used to serve the generated Ignition files via `http.server`.
* **.sops.yaml**: Defines path-based creation rules and maps profiles to their respective post-quantum Age public keys.

---

## 📖 Just Recipes

### 🏗️ Build & Provisioning

| Command | Description |
| --- | --- |
| `just run` | **The Full Pipeline:** Cleans, lints, builds, validates, and serves the Ignition files. Automatically cleans up on exit. |
| `just build` | Parallelly transpiles all `.bu` fragments and `main.bu` files into Ignition files using Podman. |
| `just serve` | Starts a local Python HTTP server inside the `servers/` directory to host generated `.ign` files. |
| `just validate` | Pulls the latest container and uses `ignition-validate` via Podman to check the integrity of all generated `.ign` files. |

### 🔐 Secrets & Key Management

*Note: These commands securely interact with your Bitwarden vault and SOPS/Age.*

| Command | Description |
| --- | --- |
| `just generate-age-key <profile>` | Generates a post-quantum age key pair (ML-KEM-768 + X25519) and uploads it to Bitwarden. |
| `just rotate-age-key <profile>` | Rotates an existing age key atomically, updates Bitwarden, and re-encrypts profile files. |
| `just encrypt <profile> [force]` | Selectively encrypts modified Butane files in a profile using SOPS and `.sops.yaml` rules. |
| `just decrypt <profile> [force]` | Decrypts all `.enc.bu` files for a profile into `.bu` files with accidental overwrite protection. |
| `just publish-key <profile> [pubkey]` | Publishes or updates a profile's public key in `.sops.yaml`. |
| `just unpublish-key <profile> [pubkey]` | Removes a profile's public key (and cleans up empty creation rules) from `.sops.yaml`. |

### 🔍 Verification & Diagnostics

| Command | Description |
| --- | --- |
| `just lint` | Validates the YAML syntax of all Butane fragments using `yamllint` (via Podman container or native binary). |
| `just diff <profile>` | Detects configuration drift by comparing encrypted files against unencrypted copies for a profile. |
| `just diff-file <profile> <enc_path>` | Decrypts a specific encrypted file temporarily and compares it against its unencrypted counterpart. |
| `just drift <profile>` | Detects configuration drift by checking target infrastructure files against defined fragments. |
| `just needs-rekey <profile>` | Checks whether a profile's encrypted file headers are synchronized with `.sops.yaml` creation rules. |

### 🔧 Maintenance & Utility

| Command | Description |
| --- | --- |
| `just setup` | Prepares a WSL2/Ubuntu environment by automatically installing required system dependencies (Butane, Podman, YAMLLint, Python). |
| `just update` | Updates the `.just/shared` submodule to its latest remote version (`git submodule update --remote .just/shared`). |
| `just download-iso` | Uses Podman to download the latest stable Fedora CoreOS ISO. |
| `just clean` | Removes all generated Ignition (`.ign`) files across servers. |
| `just create-profile <profile>` | Initializes a new server profile directory structure, template hooks, and a base `main.bu` (v1.7.0). |

---

## ⚙️ Workflow

1. **Environment Preparation:** Run `just setup` (on WSL2/Ubuntu) to ensure all tools are present.
2. **Profile Creation:** Run `just create-profile <profile>` to scaffold the node's directory structure, pre/post-build hooks, and template configuration.
3. **Key & Secret Setup:** Follow the printed instructions to run `just generate-age-key <profile>` to initialize your post-quantum security layer in Bitwarden and publish its public key to `.sops.yaml`.

4. **Configuration:** Add custom system fragments under `servers/<profile>/` and encrypt any sensitive files using `just encrypt <profile>`.
5. **Deployment:** Run `just run` to clean, build, validate, and host your profiles in one seamless command.

---

## 💡 Example Server Deployment

To deploy a new server profile named `web-node`, run:

```bash
just create-profile web-node

```

This scaffolds the profile structure under `servers/web-node/`:

```text
servers/web-node/
├── .hooks/
│   ├── pre-build
│   └── post-build
└── main.bu

```

The generated template `main.bu` uses Fedora CoreOS v1.7.0:

```yaml
variant: fcos
version: 1.7.0

```

From there, follow the post-creation instructions to generate your age key, write your custom system configurations, and run:

```bash
just run

```

The system will build `web-node.ign` and serve it at `http://<your-ip>:8000/web-node.ign`.
