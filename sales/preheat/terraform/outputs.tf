output "extension_attribute_ids" {
  description = "Jamf Pro IDs of the computer EAs, by short name."
  value       = merge({ for k, ea in jamfplatform_pro_computer_extension_attribute.script : k => ea.id }, { "content-cache-macos-readiness" = jamfplatform_pro_computer_extension_attribute.readiness.id })
}

output "smart_group_ids" {
  description = "Jamf Pro IDs of the Smart Computer Groups, by name."
  value       = { for k, g in jamfplatform_pro_smart_computer_group.preheat : k => g.id }
}

output "labels_policy_id" {
  value = jamfplatform_pro_policy.labels.id
}
