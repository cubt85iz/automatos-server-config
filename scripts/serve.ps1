if (Test-Path ".generated")
{
  Push-Location ".generated"
  if (!(Test-Path "config.ign"))
  {
    just build
  }
  python -m http.server
}