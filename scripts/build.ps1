# Pull the latest image
docker pull -q quay.io/coreos/butane:release

# Search for butane files
$files = @{}
Get-ChildItem config -Filter "*.txt" -Recurse | ForEach-Object {

  # Determine relative path to file
  $relativePath =  $_ | Resolve-Path -Relative
  
  # Calculate depth
  $depth = ($relativePath.ToCharArray() | Where-Object {
    $_ -eq '\'
  }).Count - 2

  # Add values to dictionary
  $files[$relativePath] = $depth
}

# Sort files in descending order by value (depth); ascending order by key (path)
$sortedFiles = $files.GetEnumerator() | Sort-Object @{Expression="Value"; Ascending=$false}, @{Expression="Key"; Ascending=$true}

# Iterate over sorted files and generate ignition files.
$sortedFiles | ForEach-Object {
  $file = .generated\$_.Key
  $parent = Split-Path $file

  # Create parent directory for 
  if (!(Test-Path "$parent")) {
    New-Item -ItemType Directory -Path $parent
  }

  if ( $_.Value -eq 0 ) {
    $_.Key | docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir . > $file
  }
  else {
    $_.Key | docker run --rm -i -v .:/files --workdir /files quay.io/coreos/butane:release --pretty --files-dir .generated > $file
  }
}
