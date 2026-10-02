# The script that names cached files, and the policy that runs it on every cache server at check-in.
# No Jamf credentials on the server: the script only asks Apple's public lookup service.

resource "jamfplatform_pro_script" "labels" {
  name            = "preheat-labels.py"
  info            = "Names the OS update files a content cache holds. No Jamf credentials. See the preheat README."
  notes           = "Managed by Terraform (preheat/terraform)."
  priority        = "AFTER"
  script_contents = file("${path.module}/../admin/preheat-labels.py")
}

resource "jamfplatform_pro_policy" "labels" {
  general = {
    name            = "Preheat - Refresh cache labels"
    enabled         = var.labels_policy_enabled
    frequency       = "Ongoing"
    trigger_checkin = true
  }
  scope = {
    targets = {
      computer_group_ids = [jamfplatform_pro_smart_computer_group.preheat["Content Caching - Servers"].id]
    }
  }
  scripts = {
    scripts = [{ id = jamfplatform_pro_script.labels.id, priority = "After" }]
  }
  maintenance = {
    update_inventory = true
  }
}
