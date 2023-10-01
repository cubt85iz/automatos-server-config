#!/usr/bin/env python3

from jinja2 import Environment, FileSystemLoader
import yaml, argparse
import os.path

# Define location for Jinja2 templates
templates_path = "./templates"

# Define arguments for script
parser = argparse.ArgumentParser()
parser.add_argument("template")
parser.add_argument("secrets")

# Parse arguments into variables.
args = parser.parse_args()
template = args.template
secrets = args.secrets

# Determine output location
output = os.path.join(os.path.dirname(template), os.path.basename(template)[:-3])

# Load secrets from configuration file into dictionary.
secrets = yaml.safe_load(open(secrets, 'r'))

# Open template
j2_environment = Environment(loader=FileSystemLoader(templates_path))
j2_template = j2_environment.get_template(template)

# Render template
j2_rendered_template = j2_template.render(secrets)

# Write rendered template to specified file.
if (output != None):
  # Ensure path to output file exists.
  if not os.path.exists(os.path.dirname(output)):
    os.makedirs(os.path.dirname(output))

  with open(output, '+w') as file:
    file.write(j2_rendered_template)
