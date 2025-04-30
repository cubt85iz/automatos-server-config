# Helper for build recipe.
# [windows]
# [private]
# build-ignition file depth:
#     $parent = Split-Path {{ file }}
  
#     # Create parent directory for 
#     if (!(Test-Path "$parent")) {
#       New-Item -ItemType Directory -Path $parent
#     }
  
#     if ( $_.Value -eq 0 ) {
#       {{ file }} | docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir . > $file
#     }
#     else {
#       {{ file }} | docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir .generated > $file
#     }

# Helper for validate recipe.
# [windows]
# [private]
# validate-ignition file:
#   Write-Error "Not implemented."

# Transpiles butane configuration(s) to create ignition file(s)
[windows]
build:
  #!powershell.exe

  # Pull the latest image
  docker pull -q quay.io/coreos/butane:release
  
  # Search for butane files
  $files = @{}
  Get-ChildItem config -Filter "*.bu" -Recurse | ForEach-Object {
  
    # Determine relative path to file
    $relativePath =  ($_ | Resolve-Path -Relative) -replace '\\', '/'
    
    # Calculate depth
    $depth = ($relativePath.ToCharArray() | Where-Object {
      $_ -eq '/'
    }).Count - 2
  
    # Add values to dictionary
    $files[$relativePath] = $depth
  }
  
  # Sort files in descending order by value (depth); ascending order by key (path)
  $sortedFiles = $files.GetEnumerator() | Sort-Object @{Expression="Value"; Ascending=$false}, Name
  
  # Iterate over sorted files and generate ignition files.
  $sortedFiles | ForEach-Object {
    $file = (Join-Path -Path ".generated" -ChildPath $_.Key) -replace '\.\\' -replace '\\', '/' -replace '\.bu', '.ign'
    $parent = Split-Path $file -Parent
  
    # Create parent directory for 
    if (!(Test-Path "$parent")) {
      New-Item -ItemType Directory -Path $parent | Out-Null
    }
  
    if ( $_.Value -ne 0 ) {
      docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir . $_.Key > $file
    }
    else {
      docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir .generated $_.Key > $file
    }
  }

# Remove all rendered ignition files.
[windows]
clean:
  #!powershell.exe
  if (Test-Path(".generated")) {
    Remove-Item .generated -Recurse -Force
  }

# Creates archives for configurations
# [windows]
# create-archives *config:
#   Write-Error "Not implemented."

# Extract archives for configurations
# [windows]
# extract-archives *config:
#   Write-Error "Not implemented."

# Lint butane files using yamllint.
[windows]
lint:
  #!powershell.exe

  # Pull the latest image
  docker pull -q docker.io/pipelinecomponents/yamllint:latest

  Get-ChildItem config -Filter "*.bu" -Recurse | ForEach-Object {

    #Determine relative path to file
    $relativePath = ($_ | Resolve-Path -Relative) -replace '\\', '/'

    # Lint butane file
    Write-Host "Linting butane file: $relativePath"
    docker run --rm -v .:/code docker.io/pipelinecomponents/yamllint:latest yamllint "$relativePath"
  }

# Hosts the ignition file for deployment
# [windows]
# serve:
#   #!powershell.exe

#   if (Test-Path ".generated")
#   {
#     Push-Location ".generated"
#     if (!(Test-Path "*.ign"))
#     {
#       just build
#     }
#     python -m http.server
#   }
  
# Installs the necessary applications for development.
[windows]
setup:
  #!powershell.exe
  #Requires -RunAsAdministrator

  winget import -i apps.json

# [windows]
# validate:
#   #!powershell.exe

#   # Pull the latest image
#   docker pull -q quay.io/coreos/ignition-validate:release

#   Get-ChildItem .generated/config -Filter "*.ign" -Recurse | ForEach-Object {

#     # Determine relative path to file
#     $relativePath = $_ | Resolve-Path -Relative

#     # Validate ignition file
#     just validate-ignition $_
#   }
