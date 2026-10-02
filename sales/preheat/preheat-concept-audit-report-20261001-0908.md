# Preheat — Jamf Concepts Compliance Audit Report

**Audit date:** 2026-10-01 09:08  
**Auditor:** Claude Code (concepts-audit skill v0.6.2)  
**Audit branch:** `concepts-audit-preheat-20261001-0908`  
**Repository:** https://github.com/masterstompie/preheat  
**Project slug:** `preheat`  
**Distribution intent:** Undecided / GitHub only for now — discuss with Jamf Concepts team in `#C0C37JJNNAY`

---

## Executive Summary

Preheat is a Python + Shell + Terraform admin toolset that tells Jamf Pro administrators whether each Apple content cache server is ready for an impending OS update push, and can pre-fill the cache when it is not. The code is well-written and secure, with no hardcoded credentials, proper macOS Keychain usage, and a clean gitleaks pass across 109 commits.

The project has several significant structural gaps that must be resolved before it can be published as a Jamf Concepts project. The three blockers are:

1. **Wrong GitHub organization** — the repo is under `masterstompie/preheat`, not `jamf-concepts/preheat`. Migration is required.
2. **Wrong license** — MIT with personal copyright must be replaced with the Jamf Concepts Use Agreement or Jamf Source Available License with `Jamf Software LLC` copyright. License choice is currently undecided.
3. **No CI/CD or SonarQube** — Paved Roads requires a Jenkins pipeline with SonarQube quality gates. Neither is present.

Secondary items resolved on the audit branch: `catalog-info.yaml` created, `dependabot.yml` created for the terraform ecosystem, `.gitignore` updated, and README expanded with License, Privacy, and Bill of Materials sections.

| Area | Status |
|---|---|
| Repository location | ❌ NON-COMPLIANT |
| Visibility | ✅ Private |
| Branch protection | ⚠️ Not configured (personal account limitation) |
| SonarQube | ❌ Not found |
| Dependabot | ⚠️ Created on audit branch — merge required |
| CI/CD | ❌ Not configured |
| Secrets scan (gitleaks) | ✅ Pass — 109 commits, 0 findings |
| Static analysis (CodeQL) | ⚠️ Skipped — query packs unavailable locally |
| catalog-info.yaml | ⚠️ Created on audit branch — merge required |
| License | ❌ MIT (wrong); intent undecided |
| Repo access | ⚠️ 4 individual collaborators, no LDAP teams |
| Code quality | ✅ Well-structured, no security findings |
| README | ⚠️ Expanded on audit branch — merge required |

---

## 1. Repository Location

**Status: ❌ NON-COMPLIANT**

The repository is hosted at `github.com/masterstompie/preheat` under a personal GitHub account. All Jamf Concepts projects must be hosted under the `jamf-concepts` GitHub organization.

**Required action:** Submit a request to the Jamf Concepts team to have the repository transferred or re-created under `github.com/jamf-concepts/preheat`. Contact the team in `#C0C37JJNNAY`.

Until the repository moves, branch protection rules, SonarQube integration, and LDAP team access cannot be correctly configured.

---

## 2. Repository Visibility

**Status: ✅ COMPLIANT**

The repository is private. This is the correct default state for a Jamf Concepts project that has not yet been formally reviewed for publication.

---

## 3. Branch Protection

**Status: ⚠️ NOT CONFIGURED**

Branch protection is not enabled on `main`. The personal free GitHub account cannot configure branch protection on private repositories.

**Required action:** This resolves automatically when the repo moves to `jamf-concepts/`. Once there, enable:

- Require pull request reviews (minimum 1 approver)
- Require status checks to pass before merging
- Enforce for administrators

---

## 4. SonarQube

**Status: ❌ NOT FOUND**

No `sonar-project.properties` file was found. No SonarQube references were found in CI configuration (no CI/CD exists).

**Required action:** After moving to `jamf-concepts/` and setting up a Jenkins pipeline, configure SonarQube analysis as part of the Jenkinsfile. Contact the Paved Roads team for the standard Jamf Concepts pipeline template.

---

## 5. Dependabot

**Status: ✅ Created on audit branch**

No `.github/dependabot.yml` existed at the start of the audit.

**Applied fix:** Created `.github/dependabot.yml` on the audit branch covering the terraform ecosystem with a weekly update schedule.

```yaml
version: 2
updates:
  - package-ecosystem: terraform
    directory: /terraform
    schedule:
      interval: weekly
```

The Python code uses only stdlib — no pip dependency manifest needed. The Terraform configuration uses the `jamf/jamfplatform` provider (≥ 0.29) which Dependabot will now monitor.

**Note on Dependabot vulnerability alerts:** Alerts could not be verified via the GitHub API (personal account, private repo). Enable them under **Settings → Security → Code security and analysis** once the repo moves to `jamf-concepts/`.

---

## 6. CI/CD

**Status: ❌ NOT CONFIGURED**

No `.github/workflows/` directory and no `Jenkinsfile` were found.

**Required action:** After moving to `jamf-concepts/`, create a Jenkinsfile following the standard Jamf Concepts pipeline template. Minimum pipeline stages: lint → test → SonarQube → build/package.

Because this is a Python admin script (not a compiled app or distributed binary), the "build" stage may be minimal. However, linting (`ruff`) and SonarQube quality gates are still required.

---

## 7. Secrets Scan — Gitleaks

**Status: ✅ PASS**

Gitleaks 8.30.1 scanned the full git history of 109 commits and found 0 secrets. This is an excellent result given the project's credential-heavy purpose (Jamf Pro API client credentials, keychain access).

Key observations from manual code review:
- Credentials are loaded from macOS Keychain (`security find-generic-password -s preheat`) or environment variables only
- No credentials are hardcoded in any source file
- `.gitignore` correctly excludes `*.env` and `.jamf-readiness*`
- `terraform/terraform.tfvars` (which would contain real variable values) is gitignored

---

## 8. Static Analysis — CodeQL

**Status: ⚠️ SKIPPED**

CodeQL 2.27.1 (installed via Homebrew) is available, but the Python query packs (`codeql/python-queries`) are not bundled with the Homebrew installation. Attempting to run the analysis produced:

> `Query pack codeql/python-queries:codeql-suites/python-security-and-quality.qls cannot be found`

The CodeQL database was created successfully (`--build-mode=none` for Python), but analysis could not proceed. Temp files were cleaned up.

**Required action:** Configure CodeQL as a GitHub Actions workflow using `github/codeql-action` — this runs with the full query pack registry available in GitHub's CI environment and does not require local query pack downloads.

```yaml
# .github/workflows/codeql.yml (example)
name: CodeQL
on: [push, pull_request]
jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with:
          languages: python
      - uses: github/codeql-action/analyze@v3
```

---

## 9. Repository Access

**Status: ⚠️ NON-COMPLIANT**

Current access is via 4 individual GitHub collaborators:

| User | Permission |
|---|---|
| masterstompie | Admin |
| daniel-maclaughlin | Write |
| markbuffington | Write |
| seposium | Write |

Jamf Concepts Paved Roads requires access to be granted through Crews/LDAP groups, not individual user accounts. Individual collaborator access is not auditable and cannot be centrally managed.

**Required action:** After moving to `jamf-concepts/`, remove individual collaborators and grant access through appropriate Crews/LDAP teams. Work with your manager or the Paved Roads team to identify the correct groups.

---

## 10. License

**Status: ❌ WRONG LICENSE**

The current `LICENSE` file contains the MIT License with copyright `masterstompie (StompieVision_Labs)`. Both the license and the copyright holder are incorrect for a Jamf Concepts project.

**Distribution intent:** Undecided. The user indicated uncertainty about whether the project will be distributed as source-available or under a more permissive license. Discuss with the Jamf Concepts team (Josh, Daniel, Mark in `#C0C37JJNNAY`).

**The two standard paths:**

| Path | License | Copyright | Best for |
|---|---|---|---|
| Internal/tools (default) | Jamf Concepts Use Agreement | Jamf Software LLC | Admin tools used by Jamf admins |
| Source-available | Jamf Source Available License | Jamf Software LLC | Tools the community can read and adapt |

**Required action:** 
1. Decide on the distribution path with the Jamf Concepts team
2. Replace the `LICENSE` file with the correct Jamf license text
3. Update the copyright in `LICENSE` to `Copyright © [year] Jamf Software LLC. All rights reserved.`
4. Update the `## License` section now added to `README.md` to match

**Note:** The `## License` section has been added to the README on the audit branch with placeholder text referencing the Jamf Concepts Use Agreement. Update it to match the final license decision.

---

## 11. Catalog Info (Backstage)

**Status: ✅ Created on audit branch**

`catalog-info.yaml` was missing at the start of the audit.

**Applied fix:** Created `catalog-info.yaml` at the repo root on the audit branch:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: preheat
spec:
  type: tooling
  lifecycle: experimental
  owner: concepts
  system: jamf-concept-projects
```

**Required action:** Update the `owner` field to the correct Crews team before merging. Confirm the correct team name with the Jamf Concepts team.

---

## 12. .gitignore

**Status: ✅ COMPLIANT (updated on audit branch)**

The existing `.gitignore` was well-maintained — it covered credential files, macOS noise, lab notes, and Terraform state.

**Applied fix:** Added the following entries on the audit branch:

```
# Claude Code local settings (machine-specific, may contain API keys)
.claude/settings.local.json
# Concepts audit reports (written locally; published to Confluence, not committed)
*-concept-audit-report-*.md
*-concept-audit-report-*.pdf
codeql-results-*.sarif
gitleaks-results-*.txt
```

---

## 13. Code Quality Review

**Status: ✅ STRONG**

Manual code review of `admin/readiness-check.py` (1163 lines), `admin/doctor.py`, and `admin/preheat.sh` found no security issues and sound design throughout.

### Credential handling ✅
- Credentials stored in macOS Keychain using `security find-generic-password`
- Falls back to environment variables (`JAMF_URL`, `JAMF_CLIENT_ID`, `JAMF_CLIENT_SECRET`)
- No credentials embedded in source
- OAuth token refresh via `/api/oauth/token` with proper error handling

### API design ✅
- `User-Agent: preheat/1.0` on all Apple API calls (gdmf.apple.com, api.appledb.dev)
- Jamf Pro API calls routed through a central `Jamf.call()` method
- HTTP errors wrapped with user-friendly messages
- `ThreadPoolExecutor(8)` for parallel Apple model resolution (bounded concurrency — no unbounded parallelism)

### Python quality ✅
- Stdlib only — no third-party packages to pin or audit
- Python 3.8+ compatible
- Comprehensive `argparse` interface; every script supports `--help`
- All scripts are read-only by default; mutations require explicit `--write` flag

### Write-operation risk ⚠️
The `--write` flag in `readiness-check.py` updates extension attributes on all enrolled Mac and mobile devices. `create-smart-groups.py` creates Smart Computer Groups. `create-labels-policy.py` creates/updates scripts and policies in Jamf Pro.

These are routine Jamf Pro management operations with no scope-expansion risk, but the README should note that write operations require confirmed API permissions and are irreversible without a Jamf Pro restore.

### Test coverage ❌
No automated test suite. The `admin/sample-inventory.json` and `admin/sample-inventory-large-site.json` files serve as reproducible test inputs for manual testing (`--inventory-json`), which is better than nothing. A formal pytest suite against these fixtures would be straightforward to add.

### Lint
`ruff` is not installed. No lint results available. Recommend running `ruff check admin/` before the first production deployment.

---

## 14. Jamf Pro API

**Status: ✅ COMPLIANT**

The project correctly uses Jamf Pro's OAuth client credentials flow (`/api/oauth/token`). API privileges required for each feature are documented in `docs/SETUP.md` in a table at lines 99–107 (linked from the main README).

**Credentials:** Stored in macOS Keychain under the service name `preheat`. Environment variable fallback present.

**External services accessed:**
| Service | Purpose | Personally Identifiable Data Sent |
|---|---|---|
| `gdmf.apple.com/v2/assets` | Apple's software update catalog | Hardware model identifier, OS build (no user data) |
| `api.appledb.dev` | Apple hardware/OS metadata | Hardware model identifier only |
| Jamf Pro API | Device inventory, extension attribute writes | Jamf Pro API credentials (OAuth) |

---

## 15. README Assessment

**Status: ⚠️ Partially compliant — updated on audit branch**

The README is unusually well-written for an internal tool. It clearly describes what the tool does, how it works, setup steps, and links to detailed docs.

| Element | Before audit | After audit branch fixes |
|---|---|---|
| Project title | ✅ | ✅ |
| Purpose / description | ✅ | ✅ |
| Installation instructions | ✅ | ✅ |
| Usage instructions | ✅ | ✅ |
| Where to get help | ⚠️ No Issues URL | ✅ Explicit Issues URL added |
| Troubleshooting | ⚠️ In CAVEATS.md (linked) | ⚠️ Still in CAVEATS.md — acceptable |
| Logging documentation | ❌ Not present | ❌ Still missing |
| API permissions | ⚠️ In SETUP.md (linked) | ⚠️ Acceptable via link |
| License section | ❌ Missing | ✅ Added (placeholder text) |
| Copyright line | ❌ Missing | ✅ Added |
| Privacy statement | ❌ Missing | ✅ Added |
| Bill of Materials | ❌ Missing | ✅ Added (jamf/jamfplatform Terraform provider) |

**Remaining gap:** The `## License` section added on the audit branch contains placeholder text. Update it once the license decision is made with the Jamf Concepts team.

---

## 16. Bill of Materials

| Component | Kind | Version constraint | License | Category |
|---|---|---|---|---|
| `jamf/jamfplatform` | Terraform provider | ≥ 0.29 | Jamf (verify) | First-party Jamf component |
| Python stdlib | Runtime | 3.8+ | PSF | Permitted |
| `/usr/bin/curl` | System binary | macOS built-in | Apple | Permitted |

No third-party Python packages. No npm or Swift Package Manager dependencies.

**The `jamf/jamfplatform` Terraform provider** is Jamf's own provider — verify its specific license terms before any public redistribution. For internal Jamf use, this is not a concern.

---

## 17. Telemetry / TelemetryDeck

**Status: ✅ NOT PRESENT**

No TelemetryDeck, analytics, or telemetry library detected. Privacy section added to README confirms this explicitly.

---

## Required Actions — Priority Order

### Blockers (must resolve before publication)

1. **Migrate repo to `jamf-concepts/`** — contact the Concepts team in `#C0C37JJNNAY`. This unblocks branch protection, SonarQube, and LDAP team access.

2. **Replace LICENSE** — decide on Jamf Concepts Use Agreement vs. Jamf Source Available License with the Concepts team. Replace the MIT license file. Copyright must be `Jamf Software LLC`.

3. **Set up CI/CD + SonarQube** — create a Jenkinsfile with the standard Jamf Concepts pipeline after the repo moves. SonarQube quality gates are required for Paved Roads compliance.

### High priority (resolve before first external share)

4. **Replace individual collaborators with LDAP teams** — after repo moves to `jamf-concepts/`, switch from named collaborators to Crews/LDAP groups.

5. **Merge audit branch fixes** — merge `concepts-audit-preheat-20261001-0908` into `main` to apply: `catalog-info.yaml`, `.github/dependabot.yml`, `.gitignore` additions, and README improvements.

6. **Update `catalog-info.yaml` owner field** — replace `owner: concepts` with the correct Crews team name.

7. **Update README License section** — once the license decision is made, replace the placeholder text in `## License`.

### Recommended improvements (before GA)

8. **Add automated tests** — write pytest tests against the existing `sample-inventory.json` fixtures. The `--inventory-json` pathway in `readiness-check.py` is already designed for offline testing.

9. **Configure CodeQL as a GitHub Actions workflow** — use `github/codeql-action` in CI rather than running locally. Query packs are available in the GitHub CI environment.

10. **Run `ruff` and address findings** — `ruff check admin/` before the first production release.

11. **Document logging** — add a brief note to the README (or a dedicated section in `docs/USAGE.md`) about what is logged, where, and how to increase verbosity when troubleshooting.

---

## Audit Branch Changes Summary

The following files were created or modified on `concepts-audit-preheat-20261001-0908`:

| File | Action | Description |
|---|---|---|
| `catalog-info.yaml` | Created | Backstage component descriptor |
| `.github/dependabot.yml` | Created | Weekly Dependabot updates for terraform ecosystem |
| `.gitignore` | Updated | Added audit reports, CodeQL SARIF, gitleaks output, `.claude/settings.local.json` |
| `README.md` | Updated | Added License, Privacy, Bill of Materials sections; explicit Issues URL |

Files NOT modified (require human decision):
- `LICENSE` — wrong license, but replacement requires a license decision
- `catalog-info.yaml` `owner` field — requires correct Crews team name
- Any source code — no code issues found requiring automated fixes

---

*This report was generated by the Jamf Concepts audit skill and is intended for internal use only. It should be published to Confluence under the Jamf Concepts project space — not committed to GitHub.*
