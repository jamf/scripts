variable "cache_servers" {
  description = "Per-office cache servers to make \"served by\" groups for: label (used in the group name) and the server GUID from the Content Caching section of its inventory. Leave empty on first apply and fill in once the status EA has reported."
  type = map(object({
    guid = string
  }))
  default = {}
}

variable "labels_policy_enabled" {
  description = "Whether the policy that names cached files on each cache server is enabled."
  type        = bool
  default     = true
}

variable "site_id" {
  description = "Jamf Pro site for every object, -1 for none."
  type        = string
  default     = "-1"
}
