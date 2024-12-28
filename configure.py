#!/usr/bin/env python3

import glob
from jinja2 import Environment, FileSystemLoader
import yaml, argparse
import os.path

def render_template(template, secret, destination = None):
  # Render provided template using provided secret
  j2_environment = Environment(loader=FileSystemLoader(templates_path), trim_blocks=True, lstrip_blocks=True)
  j2_template = j2_environment.get_template(template)
  j2_rendered_template = j2_template.render(secret)

  if destination == None:
    destination = os.path.join(".generated", os.path.dirname(template), os.path.basename(template)[:-3])
  
  destination_folder = os.path.dirname(destination)
  if not os.path.exists(destination_folder):
    os.makedirs(destination_folder)

  with open(f"{destination}", "+w") as file:
    file.write(j2_rendered_template)

def generate_butane_configurations():
  excluded_files = ["path.mount.j2", "container-backup.conf.j2", "container-config.env.j2", "container-core.conf.j2", "container-healthcheck-override.conf.j2",
                    "container-override.conf.j2", "environment.j2", "network.nmconnection.j2", "rclone.conf.j2", "sync.env.j2", "firewalld.xml.j2"]
  for template in glob.iglob("templates/**/*.j2", recursive=True):
    if os.path.basename(template) not in excluded_files:
      render_template(template[template.index("/") + 1:], secrets)

def generate_container_config_files():
  if 'containers' in secrets and any(secrets['containers']):
    for container in secrets['containers']:
      path = f".generated/etc/containers/config/{container['name']}.env"
      render_template("container-config.env.j2", container, path)

def generate_container_override_files():
  if 'containers' in secrets and any(secrets['containers']):
    # Implicit overrides
    for container in secrets['containers']:
      path = f".generated/etc/containers/systemd/{container['name']}.container.d/00-{container['name']}-core.conf"
      render_template("container-core.conf.j2", container, path)

      # Write monitor_url to a dropin for container healthchecks
      if "monitor_url" in container:
        path = f".generated/etc/systemd/system/healthcheck-container@{container['name']}.service.d/00-healthcheck-variables.conf"
        render_template("container-healthcheck.conf.j2", container, path)

      # Write variables for backup jobs
      if "backup" in container:
        path = f".generated/etc/systemd/system/backup@{container['name']}.service.d/00-backup-variables.conf"
        render_template("container-backup.conf.j2", container, path)

    # Explicit overrides
    for container in secrets['containers']:
      if 'overrides' in container:
        for override in container['overrides']:
          path = f".generated/etc/containers/systemd/{container['name']}.container.d/{override['file']}"
          render_template("container-override.conf.j2", override, path)

def generate_environment_configuration():
  if 'environment' in secrets and any(secrets['environment']):
    render_template("etc/environment.j2", secrets)

def generate_firewall_configuration():
  if 'firewall' in secrets and any(secrets['firewall']):
    for zone in secrets['firewall']:
      path = f".generated/etc/firewalld/zones/{ zone['zone'].lower() }.xml"
      render_template("firewalld.xml.j2", zone, path)

def generate_mount_units():
  if 'mounts' in secrets and any(secrets['mounts']):
    for mount in secrets['mounts']:
      escaped_mount = mount['path'].replace('-', '\\x2d')
      path = f".generated/etc/systemd/system/{escaped_mount.replace('/', '-')[1:]}.mount"
      render_template("path.mount.j2", mount, path)

def generate_network_configurations():
  if 'network' in secrets and any(secrets['network']):
    for network in secrets['network']:
      path = f".generated/etc/NetworkManager/system-connections/{ network['interface'] }.nmconnection"
      render_template("network.nmconnection.j2", network, path)
      os.chmod(path, 0o600)

def generate_rclone_configuration():
  if 'rclone' in secrets and any(secrets['rclone']):
    path = ".generated/rclone.conf"
    render_template("rclone.conf.j2", secrets, path)

def generate_sync_jobs():
  if 'sync' in secrets and any(secrets['sync']):
    for job in secrets['sync']:
      path = f".generated/etc/sync@{job['name']}.env"
      render_template("sync.env.j2", job, path)

# Define location for Jinja2 templates & secrets
templates_path = "./templates"
secrets = "secrets.yml"

# Load secrets from configuration file into dictionary.
secrets = yaml.safe_load(open(secrets, 'r'))

# Generate systemd mount units
generate_mount_units()

# Generate environment files for containers
generate_container_config_files()

# Generate override files for containers
generate_container_override_files()

# Generate butane configuration for transpilation
generate_butane_configurations()

# Generate rclone configuration
generate_rclone_configuration()

# Generate sync jobs
generate_sync_jobs()

# Generate firewall configuration
generate_firewall_configuration()

# Generate NetworkManager configuration files
generate_network_configurations()
