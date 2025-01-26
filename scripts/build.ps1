# Install dependencies
just install-deps

# Configure if not previously executed
if (!(Test-Path "config.bu"))
{
  just configure
}

# Build primary configuration
butane -p -d . -o config.ign config.bu