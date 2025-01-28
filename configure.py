#!/usr/bin/env python3

"""
Renders Jinja2 templates to produce butane-compatible configurations
that can be rendered into ignition files for Fedora CoreOS installations.
"""

import glob
import os.path
from jinja2 import Environment, FileSystemLoader
import yaml
import sys

def render_template(template, secret, destination = None):
  """
  Renders the provided Jinja2 template using the provided secrets and
  outputs the result to the specified destination.
  """
  # Render provided template using provided secret
  j2_environment = Environment(loader=FileSystemLoader(TEMPLATES_PATH), trim_blocks=True,
                               lstrip_blocks=True)
  j2_template = j2_environment.get_template(template)
  j2_rendered_template = j2_template.render(secret)

  if destination is None:
    destination = os.path.join(".generated", os.path.dirname(template),
                               os.path.basename(template)[:-3])

  destination_folder = os.path.dirname(destination)
  if not os.path.exists(destination_folder):
    os.makedirs(destination_folder)

  with open(f"{destination}", "+w", encoding="utf_8") as file:
    file.write(j2_rendered_template)

def generate_butane_configurations():
  """
  Searches the templates folder for templates that are not excluded and
  sends them to the renderer. Each of the excluded templates have a specialized
  function for processing.
  """
  excluded_files = ["path.mount.j2", "container-backup.conf.j2", "container-core.conf.j2",
                    "container-healthcheck.conf.j2", "container-override.conf.j2",
                    "environment.j2", "firewalld.xml.j2", "monitor.path.j2", "monitor.service.j2",
                    "network.nmconnection.j2", "rclone.conf.j2", "sync.conf.j2", "timer.j2"]
  for template in glob.iglob("templates/**/*.j2", recursive=True):
    if os.path.basename(template) not in excluded_files:
      # Jinja2 requires use of forward slashes instead of platform-specific path
      render_template((template[template.index(os.path.sep) + 1:]).replace(os.path.sep, '/'), SECRETS)

def generate_container_override_files():
  """
  Renders Jinja2 templates for the drop-in configuration files for a container's secrets,
  healthchecks, and backup jobs.
  """
  if 'containers' in SECRETS and SECRETS['containers'] and any(SECRETS['containers']):
    # Implicit overrides
    for container in SECRETS['containers']:
      path = (f".generated/etc/containers/systemd/{container['name']}.container.d/"
              f"00-{container['name']}-core.conf")
      render_template("container-core.conf.j2", container, path)

      # Remove empty core dropin files.
      if os.path.getsize(path) == 0:
        print(f"INFO: Removed empty drop-in file: {path}")
        os.remove(path)

      # Write monitor_url to a dropin for container healthchecks
      if "monitor_url" in container:
        path = (".generated/etc/systemd/system/"
                f"healthcheck-container@{container['name']}.service.d/"
                "00-healthcheck-variables.conf")
        render_template("container-healthcheck.conf.j2", container, path)

      # Write variables for backup jobs
      if "backup" in container:
        path = (f".generated/etc/systemd/system/backup@{container['name']}.service.d/"
                "00-backup-variables.conf")
        render_template("container-backup.conf.j2", container, path)

    # Explicit overrides
    for container in SECRETS['containers']:
      if 'overrides' in container:
        for override in container['overrides']:
          path = (f".generated/etc/containers/systemd/{container['name']}.container.d/"
                  f"{override['file']}")
          render_template("container-override.conf.j2", override, path)

def generate_environment_configuration():
  """
  Renders a Jinja2 template for /etc/environment file. It's useful for specifying variables
  that are required by many containers, but are not unique to any container.
  """
  if 'environment' in SECRETS and SECRETS['environment'] and any(SECRETS['environment']):
    render_template("etc/environment.j2", SECRETS)

def generate_firewall_configuration():
  """
  Renders a Jinja2 template to create firewall configurations for the specified zones.
  """
  if 'firewall' in SECRETS and SECRETS['firewall'] and any(SECRETS['firewall']):
    for zone in SECRETS['firewall']:
      path = f".generated/etc/firewalld/zones/{ zone['zone'].lower() }.xml"
      render_template("firewalld.xml.j2", zone, path)

def generate_monitor_units():
  """
  Renders Jinja2 templates to create a filesystem monitor for the specified paths.
  """
  if 'monitors' in SECRETS and SECRETS['monitors'] and any(SECRETS['monitors']):
    for monitor in SECRETS['monitors']:
      monitor_path = f".generated/etc/systemd/system/{monitor['name']}.path"
      render_template("monitor.path.j2", monitor, monitor_path)

      service_path = f".generated/etc/systemd/system/{monitor['name']}.service"
      if 'name' in monitor['service'] and monitor['service']['name']:
        service_path = f".generated/etc/systemd/system/{monitor['service']['name']}.service"
      render_template("monitor.service.j2", monitor['service'], service_path)

def generate_mount_units():
  """
  Renders a Jinja2 template to create systemd mount units for the specified mounts.
  """
  if 'mounts' in SECRETS and SECRETS['mounts'] and any(SECRETS['mounts']):
    for mount in SECRETS['mounts']:
      escaped_mount = mount['path'].replace('-', '\\x2d').replace('/', '-')[1:]
      path = f".generated/etc/systemd/system/{escaped_mount}.mount"
      render_template("path.mount.j2", mount, path)

      # Create symlinks to enable mount for each service requiring the mount.
      for req in mount['before']:
        service_requires_directory = f".generated/etc/systemd/system/{req}.requires"
        if not os.path.exists(service_requires_directory):
          os.makedirs(service_requires_directory)

        link = f"{service_requires_directory}/{escaped_mount}.mount"
        os.symlink(f"../{escaped_mount}.mount", link)


def generate_network_configurations():
  """
  Renders a Jinja2 template to create network configurations for the specified interfaces.
  """
  if 'network' in SECRETS and SECRETS['network'] and any(SECRETS['network']):
    for network in SECRETS['network']:
      path = (".generated/etc/NetworkManager/system-connections/"
              f"{ network['interface'] }.nmconnection")
      render_template("network.nmconnection.j2", network, path)
      os.chmod(path, 0o600)

def generate_rclone_configuration():
  """
  Renders a Jinja2 template to create remotes for rclone configuration.
  """
  if 'rclone' in SECRETS and SECRETS['rclone'] and any(SECRETS['rclone']):
    path = ".generated/rclone.conf"
    render_template("rclone.conf.j2", SECRETS, path)

def generate_sync_jobs():
  """
  Renders a Jinja2 template for the drop-in configuration files for a sync job.
  """
  if 'sync' in SECRETS and SECRETS['sync'] and any(SECRETS['sync']):
    for job in SECRETS['sync']:
      path = f".generated/etc/systemd/system/sync@{job['name']}.d/00-sync-variables.conf"
      render_template("sync.conf.j2", job, path)

def generate_timers():
  """
  Renders a Jinja2 template for configuring systemd timers.
  """
  if 'timers' in SECRETS and SECRETS['timers'] and any(SECRETS['timers']):
    for timer in SECRETS['timers']:
      path = f".generated/etc/systemd/system/{timer['name']}.timer"
      render_template("timer.j2", timer, path)

# Define location for Jinja2 templates & secrets
TEMPLATES_PATH = "./templates"

# pull the command line arguments
args = sys.argv[1:]
if len(args) == 1:
  secretsfile = args[0]
else:
  secretsfile = "secretspow.yml"
print("Using secrets file: ", secretsfile)

# Load secrets from configuration file into dictionary.
with open(secretsfile, 'r', encoding="utf_8") as stream:
  SECRETS = yaml.safe_load(stream)

  # Generate systemd mount units
  generate_mount_units()

  # Generate override files for containers
  generate_container_override_files()

  # Generate environment file for system
  generate_environment_configuration()

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

  # Generate filesystem monitors
  generate_monitor_units()

  # Generate systemd timers
  generate_timers()
