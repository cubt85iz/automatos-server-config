#!/usr/bin/env python3

from jinja2 import Environment, FileSystemLoader
import yaml, argparse
import os.path

# Define location for Jinja2 templates
templates_path = "./templates"

template = "path.mount.j2"
secrets = "secrets.yml"

# Determine output location
output = os.path.join(os.path.dirname(template), os.path.basename(template)[:-3])

# Load secrets from configuration file into dictionary.
secrets = yaml.safe_load(open(secrets, 'r'))

# Open template
j2_environment = Environment(loader=FileSystemLoader(templates_path), trim_blocks=True, lstrip_blocks=True)
j2_template = j2_environment.get_template(template)

for mount in secrets['mounts']:
  # Determine destination for mount unit
  destination = f".generated/etc/systemd/system/{mount['path'].replace('/', '-')[1:]}.mount"

  # Render template
  j2_rendered_template = j2_template.render(mount)

  # Ensure path to output file exists.
  destination_path=os.path.dirname(destination)
  if not os.path.exists(destination_path):
    os.makedirs(destination_path)

  # Write rendered template to specified file.
  with open(destination, '+w') as file:
    file.write(j2_rendered_template)
