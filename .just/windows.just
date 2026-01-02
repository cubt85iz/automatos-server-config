# Transpiles butane configuration(s) to create ignition file(s)
[windows]
build:
  #!powershell.exe

  # Pull the latest image
  docker pull -q quay.io/coreos/butane:release
  
  # Search for butane files
  $files = @{}
  Get-ChildItem config -Filter "*.bu" -Recurse | ForEach-Object {

    $basename = $_.BaseName
  
    # Determine relative path to file
    $relativePath =  ($_ | Resolve-Path -Relative) -replace '\\', '/'
    
    # Calculate depth
    $depth = ($relativePath.ToCharArray() | Where-Object {
      $_ -eq '/'
    }).Count - 2
  
    # Add values to dictionary
    if ($basename -ne "main") {
      $files[$relativePath] = $depth
    }
    else {
      $files[$relativePath] = 0
    }
  }
  
  # Sort files in descending order by value (depth); ascending order by key (path)
  $sortedFiles = $files.GetEnumerator() | Sort-Object @{Expression="Value"; Ascending=$false}, @{Expression="Name"; Ascending=$false}
  
  # Iterate over sorted files and generate ignition files.
  $sortedFiles | ForEach-Object {
    $file = (Join-Path -Path ".generated" -ChildPath $_.Key) -replace '\.\\' -replace '\\', '/' -replace '\.bu', '.ign'
    $parent = Split-Path $file -Parent
  
    # Create parent directory for 
    if (!(Test-Path "$parent")) {
      New-Item -ItemType Directory -Path $parent | Out-Null
    }

    Write-Host "Generating ignition file: $file"
  
    if ( $_.Value -ne 0 ) {
      docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir . $_.Key > $file
    }
    else {
      $file = ($parent + ".ign") -replace "\\", "/"
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
[windows]
create-archives *config:
  #!powershell.exe

  if (!(Test-Path("config/.archives"))) {
    New-Item -ItemType Directory config/.archives | Out-Null
  }

  $folders=@()
  if ([string]::IsNullOrEmpty("{{ config }}")) {
    $folders = Get-ChildItem -Directory "config"
  }
  else {
    $folders = "{{ config }}" -Split ' '
  }

  $folders | Where-Object {
    $_.Name -ne ".archives"
  } | ForEach-Object {
    $folderName = $_.Name
    $archive = "config/.archives/$folderName.tar"
    $pattern = "config/$folderName*"
    tar cf "$archive" $pattern
    Write-Host "Created archive: $archive"
  }


# Extract archives for configurations
[windows]
extract-archives *config:
  #!powershell.exe

  $archives=@()
  if ([string]::IsNullOrEmpty("{{ config }}")) {
    $archives = Get-ChildItem "config/.archives/*.tar"
  }
  else {
    $archives = "{{ config }}" -split ' ' | ForEach-Object {
      "config/.archives/$_.tar"
    }
  }
  
  $archives | ForEach-Object {
    $relativePath = $_ | Resolve-Path -Relative
    tar xf "$relativePath"
    echo "Extracted archive: $relativePath"
  }

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
[windows]
serve:
  #!powershell.exe

  if (Test-Path ".generated")
  {
    Push-Location ".generated"

    python -m http.server
  }
  
# Installs the necessary applications for development.
[windows]
setup:
  #!powershell.exe
  #Requires -RunAsAdministrator

  winget import -i apps.json

[windows]
validate:
  #!powershell.exe

  # Pull the latest image
  docker pull -q quay.io/coreos/ignition-validate:release

  Get-ChildItem .generated/config -Filter "*.ign" -Recurse | ForEach-Object {

    # Determine relative path to file
    $relativePath = $_ | Resolve-Path -Relative

    # Validate ignition file
    Write-Host "Validating ignition file: $relativePath"
    Get-Content "$relativePath" | docker run --rm -i quay.io/coreos/ignition-validate:release -
  }
