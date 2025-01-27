# Install dependencies
just install-deps

# Configure if not previously executed
if (!(Test-Path ".generated\config.bu"))
{
  just configure
}

if (Test-Path(".generated"))
{
  Push-Location ".generated"

  # Build primary configuration
  butane -p -d . -o config.ign config.bu

  Pop-Location
}
