# Fedora CoreOS Infrastructure Blueprint

Declarative and reproducible homelab infrastructure managed via **Fedora CoreOS** and **Butane/Ignition**, orchestrated locally using `just` and `podman`.

---

## 🚀 Project Objectives

* **Declarative Infrastructure:** Define the entire operating system state, storage layout, and networking as code using Butane configurations.
* **Modular Configuration:** Use Butane fragments located in `servers/` to define node-specific states.
* **Secure Secrets Management:** Protect sensitive configuration data by encrypting Butane fragments using **Mozilla SOPS** and **Age**.
* **Automated Build Pipeline:** Compile and validate Ignition provisioning files locally using parallelized `just` workflows and `podman`.

---

## 🏛️ Architectural Overview

The project follows a **Fragment-to-Provision** workflow designed for modularity and security:

1. **Configuration (Input):** System state is defined in small, modular Butane fragments (`.bu`). Sensitive data is stored in encrypted fragments (`.enc.bu`) managed by **Mozilla SOPS** and **Age**.
2. **Transpilation (Build):** The `just` task runner orchestrates a parallel build process. It utilizes **Podman** to run the official **Butane** container, ensuring the build environment is hermetic and consistent across different host machines.
3. **Provisioning (Output):** The resulting Ignition JSON files are served via a local **Python HTTP server**, allowing Fedora CoreOS nodes to fetch their configuration during the initial boot process.

---

## 📁 Repository Structure

```text
.
├── .just/            # Platform-specific task definitions
│   ├── linux/        # Linux-specific helpers
│   └── shared/       # Shared output/task helpers
├── servers/           # Node-specific Butane configuration fragments (.bu and .enc.bu)
├── requirements.txt    # Python dependencies
├── justfile           # Main task runner definitions
└── README.md          # Project documentation
```

* `.just/`: Contains platform-specific logic and helper modules for the `just` task runner.
* `servers/`: Contains the Butane configuration files. Standard fragments use `.bu`, while sensitive configurations are stored as encrypted `.enc.bu` files.
* `justfile`: The entry point for all automation tasks.

---

## 🛠️ Toolchain

* **[just](https://github.com/casey/just):** Command runner to execute tasks.
* **[podman](https://podman.io/):** Used to pull and run the Butane/Validation containers.
* **[Butane](https://github.com/coreos/butane):** For transpiling configuration into Ignition files.
* **[Mozilla SOPS](https://github.com/getsops/sops):** For managing encrypted secrets.
* **[Age](https://github.com/age-encryption/age):** Post-quantum encryption backend for SOPS.
* **[Bitwarden CLI](https://github.com/bitwarden/clients):** Used to securely store and retrieve encryption keys.
* **Python 3:** Used to serve the generated Ignition files via `http.server`.

---

## 📖 Just Recipes

### 🏗️ Build & Provisioning

| Command | Description |
| :--- | :--- |
| `just run` | **The Full Pipeline:** Performs a clean, lints, builds, validates, and serves the ignition files. Cleans up automatically on exit. |
| `just build` | Parallelly transpiles all `.bu` fragments and `main.bu` files into Ignition files using Podman. |
| `just serve` | Starts a local Python HTTP server to host the generated `.ign` files for node provisioning. |
| `just validate` | Uses `ignition-validate` via Podman to verify the integrity of the generated files. |

### 🔐 Secrets & Key Management

*Note: These commands interact with your Bitwarden vault.*

| Command | Description |
| :--- | :--- |
| `just generate-age-key <folder>` | Generates a post-quantum age key pair and uploads it to Bitwarden. |
| `just rotate-age-key <folder>` | Rotates an existing age key with a new post-quantum pair and updates Bitwarden. |
| `just encrypt <folder>` | Encrypts all `.bu` files in the specified folder using SOPS and the age key from Bitwarden. |
| `just decrypt <folder>` | Fetches the age key from Bitwarden and decrypts `.enc.bu` files into plain `.bu` files. |

### 🔍 Verification & Diagnostics

| Command | Description |
| :--- | :--- |
| `just lint` | Validates the YAML syntax of all Butane fragments using `yamllint`. |
| `just diff <server>` | Detects configuration drift by comparing current fragments against defined storage files. |

### 🔧 Maintenance & Utility

| Command | Description |
| :--- | :--- |
| `just setup` | Prepares a WSL2/Ubuntu environment by installing required system dependencies. |
| `just update` | Updates the `.just/shared` submodule to its latest version. |
| `just download-iso` | Uses Podman to download the latest stable Fedora CoreOS ISO. |
| `just clean` | Removes all generated Ignition files and directories. |

---

## ⚙️ Workflow

1. **Provisioning Environment:** Run `just setup` (on WSL2/Ubuntu) to ensure all tools are present.
2. **Secret Setup:** Use `just generate-age-key <folder>` to initialize your security layer.
3. **Configuration:** Create your modular `.bu` fragments in `servers/<folder>/`.
    * **Note:** Each server configuration **must** include a `main.bu` file to serve as the primary entry point for the build process.
    * Encrypt any sensitive configuration files using `just encrypt <folder>`.
4. **Deployment:** Run `just run` to clean, build, validate, and host the files in one seamless command.

---

## 💡 Example Server Deployment

To deploy a new server named `web-node`, create the directory `servers/web-node/` and add a `main.bu` file:

```yaml
# servers/web-node/main.bu
variant: fcos
version: 1.5.0

passwd:
  users:
    - name: admin
      groups: [wheel, sudo]
      ssh_authorized_keys:
        - ssh-ed25519 AAAAC3Nza... # Replace with your actual public key

storage:
  files:
    - path: /etc/hostname
      contents:
        inline: web-node-01
```

Once the file is created, simply run:

```bash
just run
```

The system will generate `web-node-01.ign` and serve it at `http://<your-ip>:8000/web-node-01.ign`.
