<!-- Copyright 2026, Jamf Software LLC. -->
# Preheat as a Terraform module

Everything [Jamf setup](../docs/SETUP.md#jamf-setup) does by hand or with the `admin/*.py`
scripts, as one `terraform apply`: the six computer extension attributes (five scripts, one text
field), the mobile device extension attribute, the ten Smart Groups, the labels script and its
policy. The EA and script bodies are read from `ea/` and `admin/` at plan time, so this folder is
also how a change to a script reaches Jamf.

Uses Jamf's own provider, [jamf/jamfplatform](https://registry.terraform.io/providers/jamf/jamfplatform),
which talks to the Jamf Platform API gateway, not to your Jamf Pro server. So the credential is
not a Jamf Pro API role and client: it is an **API integration registered in Jamf Account**
([account.jamf.com](https://account.jamf.com)). Register it against your **platform environment**
(the scope cannot be changed afterwards, and it is the only scope that can also reach Blueprints),
note the client ID, secret and environment ID, and tick these permissions. Jamf Account's picker
lists them by category and name with a box per action:

| Category | Permission | Actions | For |
|---|---|---|---|
| Inventory | Device extension attributes | Create, Read, Update, Delete | the seven EAs |
| Inventory | Device groups | Create, Read, Update, Delete | the Smart Groups |
| Admin identity and access | LDAP / cloud IdP | Read | the provider reads this when saving a smart computer group |
| Deployment | Scripts | Create, Read, Update, Delete | the labels script |
| Deployment | Policies | Create, Read, Update, Delete | the labels policy |
| Deployment | Blueprints | Create, Read, Update, Delete | only if you add Blueprints to the module later |

The `admin/*.py` scripts keep using the Jamf Pro API client described in [Setup](../docs/SETUP.md); the
two credentials are unrelated, and `import.sh` needs both.

    export JAMFPLATFORM_BASE_URL=https://us.api.jamfcloud.com      # or eu, apac
    export JAMFPLATFORM_CLIENT_ID=...
    export JAMFPLATFORM_CLIENT_SECRET=...
    export JAMFPLATFORM_ENVIRONMENT_ID=...
    cd terraform
    cp terraform.tfvars.example terraform.tfvars
    terraform init
    terraform plan
    terraform apply

**A tenant that already has Preheat installed** (by hand, or by the admin scripts): run
`bash import.sh` after `terraform init` and before the first `plan`. It looks each object up by name
through the Jamf Pro API and imports it, so the first apply reconciles instead of failing on
duplicate names. Expect a small diff on descriptions.

**Per-office groups**: once a cache server shows its Server GUID in Jamf (Content Caching section of its inventory), add it to `cache_servers`
in `terraform.tfvars` and apply again; the two "served by" groups appear.

Not managed here, on purpose: the API client itself (a chicken-and-egg problem: Terraform needs
credentials to make credentials), the Blueprints (they are yours to design per rollout; the
provider has `jamfplatform_blueprints_blueprint` when you want them in code too), and the SMTP and
notification settings.

Status: written 2026-09-24 against the provider's published schemas, not yet applied to a tenant,
because this lab has no Platform API integration yet. `terraform validate` needs the provider
downloaded (`terraform init`), which needs no credentials.
