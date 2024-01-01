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

def generate_mount_units():
  for mount in secrets['mounts']:
    escaped_mount = mount['path'].replace('-', '\\x2d')
    path = f".generated/etc/systemd/system/{escaped_mount.replace('/', '-')[1:]}.mount"
    render_template("path.mount.j2", mount, path)

def generate_container_config_files():
  for container in secrets['containers']:
    path = f".generated/etc/containers/config/{container['name']}.env"
    render_template("container-config.env.j2", container, path)

def generate_butane_configurations():
  for template in glob.iglob("templates/**/*.j2", recursive=True):
    if os.path.basename(template) != "path.mount.j2" and os.path.basename(template) != "container-config.env.j2":
      render_template(template[template.index("/") + 1:], secrets)

# Define location for Jinja2 templates & secrets
templates_path = "./templates"
secrets = "secrets.yml"

# Load secrets from configuration file into dictionary.
secrets = yaml.safe_load(open(secrets, 'r'))

# Generate systemd mount units
generate_mount_units()

# Generate environment files for containers
generate_container_config_files()

# Generate butane configuration for transpilation
generate_butane_configurations()