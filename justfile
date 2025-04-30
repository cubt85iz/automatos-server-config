set ignore-comments := true
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

import ".just/linux.just"
#import ".just/windows.just"

# Executes all recipes required to serve ignition files
run: clean lint build validate serve