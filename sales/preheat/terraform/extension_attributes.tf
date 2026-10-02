# The five script extension attributes, each one the file of the same name in ea/.
# Jamf runs the copy stored in the EA, so a change to a file here is a change to the EA on the next apply.

locals {
  # The name of each EA in Jamf. The admin scripts find them by these names; do not change them.
  ea_names = {
    "content-cache-status"          = "Content Caching - Status"
    "content-cache-servers-found"   = "Content Caching - Servers Found"
    "content-cache-macos-assets"    = "Content Caching - macOS Assets"
    "content-cache-decoded"         = "Content Caching - Cached Updates"
    "content-cache-effectiveness"   = "Content Caching - Effectiveness"
    "content-cache-macos-readiness" = "Content Caching - macOS Readiness"
    "content-cache-server"          = "Content Caching - Server"
  }
  ea_scripts = {
    "content-cache-status"        = "ea-content-cache-status.sh"
    "content-cache-servers-found" = "ea-content-cache-servers-found.sh"
    "content-cache-macos-assets"  = "ea-content-cache-macos-assets.sh"
    "content-cache-decoded"       = "ea-content-cache-decoded.sh"
    "content-cache-effectiveness" = "ea-content-cache-effectiveness.sh"
  }
  ea_descriptions = {
    "content-cache-status"        = "Whether this Mac runs content caching: Active with guid, addresses, port and space, or Inactive with the reason. Worked out during inventory, so the Smart Groups that raise alerts are built on it."
    "content-cache-servers-found" = "Which cache server(s) this Mac would use, as macOS decides, remembered for 90 days."
    "content-cache-macos-assets"  = "On cache servers: one line per cached OS update file, COMPLETE or PARTIAL nn%, with Apple's path. The machine key."
    "content-cache-decoded"       = "On cache servers: the same list with human names (version, build, full or delta, models), from labels.json kept current by the labels policy."
    "content-cache-effectiveness" = "On cache servers: GOOD/FAIR/LOW/NEW share of delivered bytes that did not come from Apple; WIPED for 3 days after the cache lost its content."
  }
}

resource "jamfplatform_pro_computer_extension_attribute" "script" {
  for_each          = local.ea_scripts
  name              = local.ea_names[each.key]
  description       = local.ea_descriptions[each.key]
  data_type         = "STRING"
  input_type        = "SCRIPT"
  inventory_display = "EXTENSION_ATTRIBUTES"
  enabled           = true
  script            = file("${path.module}/../ea/${each.value}")
}

# Filled by admin/readiness-check.py --write, not collected by the Mac.
resource "jamfplatform_pro_computer_extension_attribute" "readiness" {
  name              = local.ea_names["content-cache-macos-readiness"]
  description       = "Written by admin/readiness-check.py: READY / PARTIAL / NOT READY for the devices this cache server serves, then details and the time of the last check."
  data_type         = "STRING"
  input_type        = "TEXT"
  inventory_display = "EXTENSION_ATTRIBUTES"
}

# Mobile devices cannot run scripts; the admin script writes which server each one matched.
resource "jamfplatform_pro_mobile_device_extension_attribute" "server" {
  name              = local.ea_names["content-cache-server"]
  description       = "Written by admin/readiness-check.py --write: the cache server(s) this device would use, matched by public IP the way Apple's locator does, remembered for 90 days; or None found."
  data_type         = "STRING"
  input_type        = "TEXT"
  inventory_display = "EXTENSION_ATTRIBUTES"
}
