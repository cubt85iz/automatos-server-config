# Transpiles butane configuration(s) to create ignition file(s)
[windows]
build:
  ./scripts/build.ps1

# Remove all rendered ignition files.
[windows]
clean:
  Remove-Item .generated -Recurse -Force

[windows]
lint:
  Write-Error "Not Implemented."

# Hosts the ignition file for deployment
[windows]
serve:
  ./scripts/serve.ps1

[windows]
validate:
  Write-Error "Not Implemented."
