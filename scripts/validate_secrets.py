import os
import sys
import json
import yaml
from jsonschema import validate, ValidationError

def main():
    # Resolve repo root dynamically (one level up from the 'scripts/' directory)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    schema_path = os.path.join(repo_root, "schemas", "secrets.schema.json")
    
    if not os.path.exists(schema_path):
        print(f"Error: Schema file '{schema_path}' not found.")
        sys.exit(1)

    # Load schema (supports JSON or YAML)
    with open(schema_path, "r") as f:
        if schema_path.endswith(".yaml") or schema_path.endswith(".yml"):
            schema = yaml.safe_load(f)
        else:
            schema = json.load(f)

    # Find all plaintext secrets.yaml files under servers/
    secret_files = []
    for root, dirs, files in os.walk("servers"):
        for file in files:
            if file == "secrets.yaml":
                secret_files.append(os.path.join(root, file))

    if not secret_files:
        print("No plaintext secrets.yaml files found to validate.")
        return

    failed = False
    for secret_file in secret_files:
        print(f"Validating {secret_file}...")
        try:
            with open(secret_file, "r") as f:
                data = yaml.safe_load(f) or {}
            
            validate(instance=data, schema=schema)
            print(f"  [OK] {secret_file} is valid.")
        except ValidationError as e:
            print(f"  [ERROR] Validation failed for {secret_file}:")
            print(f"    Path: {' -> '.join(str(p) for p in e.path)}")
            print(f"    Message: {e.message}")
            failed = True
        except Exception as e:
            print(f"  [ERROR] Error reading {secret_file}: {e}")
            failed = True

    if failed:
        sys.exit(1)
    else:
        print("All secret files passed schema validation!")

if __name__ == "__main__":
    main()