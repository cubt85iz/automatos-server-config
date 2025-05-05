# automatos-server-config

Toolkit for managing secrets for a server based on Fedora CoreOS.

## Project Overview

This project provides recipes for building Ignition (*.ign) files from Butane(*.bu) files stored in the `config` folder.

## Usage

1. Define the Butane configuration files for your server deployments.

> [!IMPORTANT]
> Use a subfolder for each server deployment with a `main.bu` file as the primary butane configuration file. Refer to the `example-server` configuration for more information.

2. Execute `just download-iso` to download the latest Fedora CoreOS ISO file. Write the ISO to a USB drive using Etcher (or similar tool)
2. Execute `just run` to build and serve ignition files.
2. Boot into Fedora CoreOS live distribution.
2. Execute `sudo coreos-installer install --insecure-ignition --ignition-url http://<web-server-ip>:8000/config/<server>.ign <disk-device>`. Example: `sudo coreos-installer install --insecure-ignition --ignition-url http://192.168.1.100:8000/config/example-server.ign /dev/nvme0n1`.
2. Execute `poweroff`, unplug the USB drive, and power on the machine again. Follow the instructions for [automatos-server](https://github.com/cubt85iz/automatos-server.git) to rebase to new image.

> [!INFORMATION]
> For Windows development, execute the command `just setup` from an administrative Powershell window to install required dependencies.
