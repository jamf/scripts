# The Smart Groups the dashboard, alerts and Blueprints read. Every rule matches a word of an EA value,
# which is why those words never change. Jamf's own "Content Caching - ..." criteria are not used:
# Jamf collects that section just after inventory, so a group built on it is one inventory behind.

locals {
  ea_status  = jamfplatform_pro_computer_extension_attribute.script["content-cache-status"].name
  ea_found   = jamfplatform_pro_computer_extension_attribute.script["content-cache-servers-found"].name
  ea_effect  = jamfplatform_pro_computer_extension_attribute.script["content-cache-effectiveness"].name
  ea_ready   = jamfplatform_pro_computer_extension_attribute.readiness.name
  ea_mserver = jamfplatform_pro_mobile_device_extension_attribute.server.name

  computer_groups = {
    "Content Caching - Servers" = {
      description = "Macs running Apple content caching, serving or not (status EA starts with Active or Inactive)."
      criteria    = [{ name = local.ea_status, search_type = "like", value = "Active" }]
    }
    "Content Caching - Ready for OS push" = {
      description = "Cache servers whose local devices' next OS update is fully cached (readiness EA READY)."
      criteria = [
        { name = local.ea_ready, search_type = "like", value = "READY" },
        { name = local.ea_ready, search_type = "not like", value = "NOT READY", and_or = "and" },
      ]
    }
    "Content Caching - Partially ready" = {
      description = "Cache servers with some, not all, needed OS files cached."
      criteria    = [{ name = local.ea_ready, search_type = "like", value = "PARTIAL" }]
    }
    "Content Caching - Not ready" = {
      description = "Cache servers missing every needed OS file."
      criteria    = [{ name = local.ea_ready, search_type = "like", value = "NOT READY" }]
    }
    "Content Caching - Inactive or broken" = {
      description = "Caching turned on but not serving (registration failed, low space, data path missing)."
      criteria    = [{ name = local.ea_status, search_type = "like", value = "Inactive" }]
    }
    "Content Caching - Low on space" = {
      description = "Caches that report LOWSPACE: the cache volume is nearly full, missing or renamed. A cache that loses its volume switches itself off, and still shows here."
      criteria    = [{ name = local.ea_status, search_type = "like", value = "LOWSPACE" }]
    }
    "Content Caching - Low benefit" = {
      description = "Cache servers that re-serve under 30% of what they download: few devices use them, or devices cannot reach them (VPN, wrong network)."
      criteria    = [{ name = local.ea_effect, search_type = "like", value = "LOW " }]
    }
    "Content Caching - Wiped recently" = {
      description = "Cache servers that lost more than 90% of their content in the last 3 days: almost always a failed registration with Apple (VPN on the server, blocked egress, changed public IP)."
      criteria    = [{ name = local.ea_effect, search_type = "like", value = "WIPED " }]
    }
    "Macs with no content cache" = {
      description = "Macs that will download OS updates straight from Apple (locator found no cache in 90 days)."
      criteria    = [{ name = local.ea_found, search_type = "is", value = "None found" }]
    }
  }
}

resource "jamfplatform_pro_smart_computer_group" "preheat" {
  for_each    = local.computer_groups
  name        = each.key
  description = each.value.description
  site_id     = var.site_id
  criteria = [
    for i, c in each.value.criteria : {
      name        = c.name
      search_type = c.search_type
      value       = c.value
      and_or      = i == 0 ? null : lookup(c, "and_or", "and")
    }
  ]
}

resource "jamfplatform_pro_smart_mobile_device_group" "no_cache" {
  name        = "Mobile devices with no content cache"
  description = "iPads, iPhones and Apple TVs that will download OS updates straight from Apple."
  site_id     = var.site_id
  criteria    = [{ name = local.ea_mserver, search_type = "is", value = "None found" }]
}

# One pair per office, from var.cache_servers.
resource "jamfplatform_pro_smart_computer_group" "served_by" {
  for_each    = var.cache_servers
  name        = "Macs served by ${each.key} cache"
  description = "Macs whose locator reports cache server ${each.value.guid}."
  site_id     = var.site_id
  criteria    = [{ name = local.ea_found, search_type = "like", value = each.value.guid }]
}

resource "jamfplatform_pro_smart_mobile_device_group" "served_by" {
  for_each    = var.cache_servers
  name        = "Mobile devices served by ${each.key} cache"
  description = "Mobile devices matched (by public IP) to cache server ${each.value.guid}."
  site_id     = var.site_id
  criteria    = [{ name = local.ea_mserver, search_type = "like", value = each.value.guid }]
}
