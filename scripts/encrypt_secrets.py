import os
import subprocess
import glob

def main():
    # Find all servers/<server>/secrets.yaml files
    secret_files = glob.glob("servers/*/secrets.yaml")
    
    for plain_file in secret_files:
        server_dir = os.path.dirname(plain_file)
        enc_file = os.path.join(server_dir, "secrets.enc.yaml")
        
        print(f"Encrypting {plain_file} -> {enc_file}")
        
        # Run sops encryption, outputting to secrets.enc.yaml
        # SOPS automatically picks up the correct age key from .sops.yaml based on the file path
        try:
            result = subprocess.run(
                ["sops", "--encrypt", plain_file],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True
            )
            
            # Write the encrypted content to secrets.enc.yaml
            with open(enc_file, "w") as f:
                f.write(result.stdout)
                
            # Automatically stage the updated encrypted file so it's included in the commit
            subprocess.run(["git", "add", enc_file], check=True)
            
        except subprocess.CalledProcessError as e:
            print(f"Error encrypting {plain_file}: {e.stderr}")
            exit(1)

if __name__ == "__main__":
    main()
