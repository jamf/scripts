terraform {
  required_version = ">= 1.8"
  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = ">= 0.29"
    }
  }
}
