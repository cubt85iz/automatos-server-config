import os
import sys
import shutil
import yaml
from jinja2 import Environment, FileSystemLoader

def load_server_secrets(server_dir):
    """Loads secrets.yaml from the specific server directory."""
    sec_file = os.path.join(server_dir, "secrets.yaml")
    if os.path.exists(sec_file):
        with open(sec_file, 'r') as f:
            return yaml.safe_load(f) or {}
    return {}

def merge_static_files(src_dir, dest_dir):
    """Recursively copies and merges static files from src to dest without wiping dest subdirs."""
    if os.path.exists(src_dir) and os.path.isdir(src_dir):
        for item in os.listdir(src_dir):
            s = os.path.join(src_dir, item)
            d = os.path.join(dest_dir, item)
            if os.path.isdir(s):
                os.makedirs(d, exist_ok=True)
                merge_static_files(s, d)
            else:
                # Only copy if source is newer or dest doesn't exist, 
                # or just copy safely (omitting overwrite if it's a template artifact)
                shutil.copy2(s, d)

def main():
    if len(sys.argv) < 4:
        print("Usage: python3 preprocess.py <servers_dir> <templates_dir> <output_base_dir> [global_files_dir]")
        sys.exit(1)

    servers_dir = sys.argv[1]
    templates_dir = sys.argv[2]
    output_base_dir = sys.argv[3]
    global_files_dir = sys.argv[4] if len(sys.argv) > 4 else 'files/'

    if not os.path.exists(servers_dir):
        print(f"Error: Servers directory '{servers_dir}' not found.")
        sys.exit(1)

    if not os.path.exists(templates_dir):
        print(f"Error: Templates directory '{templates_dir}' not found.")
        sys.exit(1)

    server_entries = [
        d for d in os.listdir(servers_dir)
        if os.path.isdir(os.path.join(servers_dir, d))
    ]

    env = Environment(
        loader=FileSystemLoader(templates_dir),
        keep_trailing_newline=True
    )

    for server_name in server_entries:
        server_path = os.path.join(servers_dir, server_name)
        server_output_dir = os.path.join(output_base_dir, server_name)
        
        if os.path.exists(server_output_dir):
            shutil.rmtree(server_output_dir)
        os.makedirs(server_output_dir, exist_ok=True)

        print(f"\n==> Processing server: {server_name}")
        secrets = load_server_secrets(server_path)

        # 1. Render all global templates into .staging/<server_name>/
        for root, dirs, files in os.walk(templates_dir):
            template_files = [f for f in files if f.endswith('.bu') or f.endswith('.j2')]
            if not template_files:
                continue

            rel_dir = os.path.relpath(root, templates_dir)
            out_target_dir = os.path.join(server_output_dir, rel_dir if rel_dir != '.' else '')
            os.makedirs(out_target_dir, exist_ok=True)

            for file in template_files:
                template_path = os.path.relpath(os.path.join(root, file), templates_dir)
                template = env.get_template(template_path)
                rendered = template.render(**secrets)
                
                dest_file = file[:-3] if file.endswith('.j2') else file
                dest_path = os.path.join(out_target_dir, dest_file)
                
                with open(dest_path, 'w') as out_f:
                    out_f.write(rendered)

        # 2. Copy global static files
        if os.path.exists(global_files_dir):
            merge_static_files(global_files_dir, server_output_dir)

        # 3. Copy server-specific static files (including server/files/)
        server_files_dir = os.path.join(server_path, "files")
        if os.path.exists(server_files_dir):
            merge_static_files(server_files_dir, server_output_dir)

        # 4. Handle server's own main.bu (render if .j2, or copy if regular .bu)
        main_bu_j2 = os.path.join(server_path, "main.bu.j2")
        main_bu = os.path.join(server_path, "main.bu")
        dest_main_bu = os.path.join(server_output_dir, "main.bu")

        if os.path.exists(main_bu_j2):
            server_env = Environment(loader=FileSystemLoader(server_path), keep_trailing_newline=True)
            template = server_env.get_template("main.bu.j2")
            rendered = template.render(**secrets)
            with open(dest_main_bu, 'w') as out_f:
                out_f.write(rendered)
            print(f"  Rendered server main.bu.j2 -> {dest_main_bu}")
        elif os.path.exists(main_bu):
            shutil.copy2(main_bu, dest_main_bu)
            print(f"  Copied server main.bu -> {dest_main_bu}")
        else:
            print(f"  Warning: No main.bu or main.bu.j2 found in {server_path}")

if __name__ == '__main__':
    main()
