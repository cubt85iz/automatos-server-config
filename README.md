# automatos-server-config

Toolkit for managing secrets for a server based on Fedora CoreOS.

## Project Overview

This project provides recipes for building Ignition (*.ign) files from Butane(*.bu) files stored in the config folder.

## Usage

1. Define the Butane configuration files for your server deployments.
1. Execute `just download-iso` to download the latest Fedora CoreOS ISO file. Write the ISO to a USB drive using Etcher (or similar tool)
1. Execute `just serve` to build and serve ignition files.
1. Boot into Fedora CoreOS live distribution.
1. Execute `sudo coreos-installer install --insecure-ignition --ignition-url http://<web-server-ip>:8000/<server>.ign <disk-device>`. Example: `sudo coreos-installer install --insecure-ignition --ignition-url http://192.168.1.100:8000/homeassistant.ign /dev/nvme0n1`.
1. Execute `poweroff`, unplug the USB drive, and power on the machine again. Follow the instructions for [automatos-server](https://github.com/cubt85iz/automatos-server.git) to rebase to new image.

| :memo: **NOTE** |
|--|
| For Windows development, execute the command `winget import -i apps.json` from an administrative Powershell window to install required dependencies. |
