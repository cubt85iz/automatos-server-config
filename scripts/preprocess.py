import os
import sys
import yaml
from jinja2 import Environment, FileSystemLoader

def find_nearest_secrets(current_root, input_base):
    """Walks upward from current_root to input_base looking for the nearest secrets.yaml"""
    curr = current_root
    while True:
        sec_file = os.path.join(curr, "secrets.yaml")
        if os.path.exists(sec_file):
            with open(sec_file, 'r') as f:
                return yaml.safe_load(f) or {}
        
        # Stop if we've reached the input base or root
        if os.path.abspath(curr) == os.path.abspath(input_base) or curr == os.path.dirname(curr):
            break
        curr = os.path.dirname(curr)
    return {}

def main():
    input_base = sys.argv[1]
    output_base = sys.argv[2]

    if not os.path.exists(input_base):
        print(f"Error: Input directory '{input_base}' not found.")
        sys.exit(1)

    for root, dirs, files in os.walk(input_base):
        template_files = [f for f in files if f.endswith('.bu') or f.endswith('.j2')]
        if not template_files:
            continue

        rel_dir = os.path.relpath(root, input_base)
        out_server_dir = os.path.join(output_base, rel_dir if rel_dir != '.' else '')
        os.makedirs(out_server_dir, exist_ok=True)

        # Inherit secrets from the nearest parent directory containing secrets.yaml
        secrets = find_nearest_secrets(root, input_base)
        if secrets:
            print(f"DEBUG [{root}] Inherited {len(secrets)} secret keys.")
        else:
            print(f"DEBUG [{root}] No secrets found in parent hierarchy.")

        env = Environment(
            loader=FileSystemLoader(root),
            keep_trailing_newline=True
        )

        for file in template_files:
            template = env.get_template(file)
            rendered = template.render(**secrets)
            
            dest_file = file[:-3] if file.endswith('.j2') else file
            dest_path = os.path.join(out_server_dir, dest_file)
            
            with open(dest_path, 'w') as out_f:
                out_f.write(rendered)
            print(f"Rendered: {os.path.join(rel_dir, file)} -> {dest_path}")

if __name__ == '__main__':
    main()