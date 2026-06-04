This directory contains scripts created by Jamf's Support department.

Copyright 2026, Jamf Software LLC
This work is licensed under the terms of the Jamf Source Available License:
https://github.com/jamf/scripts/blob/main/LICENCE.md

# Purpose
This script is designed to run a POST against the `/api/v1/cloud-distribution-point/refresh-inventory` API endpoint in order to refresh the JCDS inventory on each pod in a Jamfcloud-hosted Jamf Pro cluster.

### USAGE:
   ./hit_all_pods_internet.zsh <fqdn>

### ARGUMENTS:
   <fqdn>    Jamf Pro FQDN, e.g. acme.jamfcloud.com

### EXAMPLE:
   ./hit_all_pods_internet.zsh acme.jamfcloud.com

### API CLIENT PRIVILEGES REQUIRED:
   - Read Cloud Distribution Point

### CREDENTIALS:
   The script will prompt for an API Client ID and Client Secret at runtime.
  These can be created in Jamf Pro under Settings → API Roles and Clients.
  The secret is entered silently (no echo) and is never written to the log file.

## Instructions
1. Create an API Role with the "Read Cloud Distribution Point" privilege. Create and enable a new API client, save the credentials.
2. In Terminal, run the script like so: `./hit_all_pods_internet.zsh <tenant>.jamfcloud.com /api/v1/cloud-distribution-point/refresh-inventory` You will be prompted for the API client credentials which can be passed securely via the Terminal.
3. There is no step 3!

### Logs
Log file will be written to /tmp/hit_all_pods_internet.log
