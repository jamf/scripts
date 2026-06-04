#!/bin/zsh --no-rcs

##########################################################################################
#
# Copyright (c) 2026, Jamf Software, LLC.  All rights reserved.
#
#       Redistribution and use in source and binary forms, with or without
#       modification, are permitted provided that the following conditions are met:
#               * Redistributions of source code must retain the above copyright
#                 notice, this list of conditions and the following disclaimer.
#               * Redistributions in binary form must reproduce the above copyright
#                 notice, this list of conditions and the following disclaimer in the
#                 documentation and/or other materials provided with the distribution.
#               * Neither the name of the JAMF Software, LLC nor the
#                 names of its contributors may be used to endorse or promote products
#                 derived from this software without specific prior written permission.
#
#       THIS SOFTWARE IS PROVIDED BY JAMF SOFTWARE, LLC "AS IS" AND ANY
#       EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#       WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#       DISCLAIMED. IN NO EVENT SHALL JAMF SOFTWARE, LLC BE LIABLE FOR ANY
#       DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#       (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#       LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#       ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#       (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#       SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
##########################################################################################
#
# DESCRIPTION
#
# Posts to /api/v1/cloud-distribution-point/refresh-inventory on every pod of a
# Jamf Pro Cloud instance, from the internet only. No kubectl or internal cluster
# access required.
#
# Uses the nginx sticky session cookie (jpro-ingress) to discover and individually
# pin to each pod, then issues an authenticated POST against each one using a bearer
# token obtained via OAuth2 client credentials.
#
# USAGE:
#   ./hit_all_pods_internet.zsh <fqdn>
#
# ARGUMENTS:
#   <fqdn>    Jamf Pro FQDN, e.g. acme.jamfcloud.com
#
# EXAMPLE:
#   ./hit_all_pods_internet.zsh acme.jamfcloud.com
#
# API CLIENT PRIVILEGES REQUIRED:
#   - Read Cloud Distribution Point
#
# CREDENTIALS:
#   The script will prompt for an API Client ID and Client Secret at runtime.
#   These can be created in Jamf Pro under Settings → API Roles and Clients.
#   The secret is entered silently (no echo) and is never written to the log file.
#
##########################################################################################
#
# CHANGE LOG
# 1.0 - Created
# 1.1 - Converted to zsh; added OAuth2 client credentials auth; switched to getopts
#       for -m/-d/-H flags; fixed (( )) arithmetic exit-status traps under set -e;
#       moved token fetch to after pod discovery; fixed local variable re-declaration
#       bleed in pod loop
# 1.2 - Locked to POST /api/v1/cloud-distribution-point/refresh-inventory; removed
#       generic path/method/header/body arguments
# 1.3 - Renamed print() to tprint() to avoid shadowing zsh builtin; locked log file
#       to 600 permissions via umask 077; fixed silent-read newline routing to terminal
#
##########################################################################################

##########################################################################################
################################### Global Variables #####################################
##########################################################################################

# Script metadata
scriptExtension=${0##*.}
swTitle=$(/usr/bin/basename "$0" ."${scriptExtension}")
ver="1.3"

# Log directory and file
debugDir="/tmp"
debugFile="${debugDir}/${swTitle}.log"

# Exit status
returncode=0

# API token variables (populated at runtime — do not edit)
api_token=""
token_expiration_epoch=0

# Runtime variables (populated via CLI args and prompts — do not edit)
FQDN=""
URL_PATH="/api/v1/cloud-distribution-point/refresh-inventory"
HTTP_METHOD="POST"
typeset -a cookies

# How many consecutive cookieless probes with no new cookie before we stop.
# 10 is sufficient for Standard (2 pods) and Premium (4 pods); raise for larger fleets.
POD_DISCOVERY_TRIES=10

##########################################################################################
#################################### Start functions #####################################
##########################################################################################


usage()
{

    # Print usage to terminal and exit

    /bin/cat <<EOF
Usage: $0 <fqdn>

Arguments:
  <fqdn>    Jamf Pro FQDN (e.g. acme.jamfcloud.com)

Example:
  $0 acme.jamfcloud.com

Posts to /api/v1/cloud-distribution-point/refresh-inventory on every pod.
Requires an API client with the "Read Cloud Distribution Point" privilege.
EOF
    exit 0

}


setup()
{

    # Initialize logging — create log file with owner-only permissions (600) so that
    # cookie values and response bodies in the log are not world-readable on shared hosts.
    ( umask 077 && /usr/bin/touch "${debugFile}" )
    /bin/chmod 600 "${debugFile}"

    # Save original terminal stdout as fd 3 before redirecting
    exec 3>&1

    # Redirect all stdout/stderr to log file only
    exec >> "${debugFile}" 2>&1

    return 0

}


start()
{

    # Log script start with metadata

    echo ""
    echo "##########################################################################################"
    echo "###########################################-START-########################################"
    echo "##########################################################################################"
    echo ""
    echo "Jamf Support - Hit All Pods"
    echo "Running ${swTitle} Version ${ver}"
    echo ""
    echo "Started: $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    echo "Target: https://${FQDN}${URL_PATH}"
    echo ""

}


finish()
{

    # Log detailed completion to file, print summary line to terminal

    echo ""
    echo "Finished: $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    if [[ $returncode -eq 0 ]]; then
        echo "Result: SUCCESS"
    else
        echo "Result: FAILED (exit code: ${returncode})"
    fi
    echo ""
    echo "##########################################################################################"
    echo "############################################-END-#########################################"
    echo "##########################################################################################"
    echo ""

    # Print outcome summary to terminal (fd 3 = original stdout)
    if [[ $returncode -eq 0 ]]; then
        echo "==> Done. Log: ${debugFile}" >&3
    else
        echo "==> Failed (exit code: ${returncode}). Log: ${debugFile}" >&3
    fi

}


log()
{

    # Timestamped log entry — writes to log file only
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') - $*"

}


tprint()
{

    # Progress message to terminal only (fd 3 = original stdout)
    echo "$*" >&3

}


promptForCredentials()
{

    # Prompt for OAuth2 API client credentials interactively

    tprint ""

    if [[ -z "${client_id}" ]]; then
        tprint -n "+ Please enter the API Client ID: "
        read -r client_id
    fi

    if [[ -z "${client_secret}" ]]; then
        tprint -n "+ Please enter the API Client Secret: "
        read -rs client_secret
        tprint "" # newline after silent input
    fi

    if [[ -z "${client_id}" ]] || [[ -z "${client_secret}" ]]; then
        tprint "ERROR: Client ID and Client Secret are required."
        log "ERROR: Missing API credentials after prompt"
        returncode=1
        return 1
    fi

    return 0

}


getAccessToken()
{

    # Fetch a new bearer token via OAuth2 client credentials
    # Returns: 0 on success, 1 on failure

    tprint "  → Requesting access token..."
    log "Requesting new access token"
    log "Token endpoint: https://${FQDN}/api/v1/oauth/token"

    local response
    response=$(/usr/bin/curl --silent --location --request POST \
        "https://${FQDN}/api/v1/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${client_id}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${client_secret}")

    api_token=$(echo "$response" | /usr/bin/plutil -extract access_token raw - 2>/dev/null)
    local token_expires_in
    token_expires_in=$(echo "$response" | /usr/bin/plutil -extract expires_in raw - 2>/dev/null)

    if [[ -z "$api_token" ]] || [[ "$api_token" == "null" ]]; then
        log "ERROR: Failed to obtain access token. Response: ${response}"
        tprint "  ✗ Failed to obtain access token — check credentials and API client permissions."
        return 1
    fi

    local current_epoch
    current_epoch=$(/bin/date +%s)
    token_expiration_epoch=$(( current_epoch + token_expires_in - 30 ))

    log "Access token obtained (expires in ${token_expires_in}s, epoch cutoff: ${token_expiration_epoch})"
    tprint "  ✓ Access token obtained (expires in ${token_expires_in}s)"
    return 0

}


checkTokenExpiration()
{

    # Refresh the token if expired or expiring within 60 seconds
    # Returns: 0 on success, 1 on failure

    local current_epoch
    current_epoch=$(/bin/date +%s)

    if [[ -n "$api_token" ]] && [[ $token_expiration_epoch -gt $current_epoch ]]; then
        log "Token still valid (epoch cutoff: ${token_expiration_epoch})"
        return 0
    else
        log "Token expired or expiring soon — refreshing"
        getAccessToken
        return $?
    fi

}


invalidateToken()
{

    # Invalidate the current bearer token

    if [[ -z "$api_token" ]]; then
        log "No token to invalidate"
        return 0
    fi

    tprint "  → Invalidating access token..."
    log "Invalidating access token"

    local responseCode
    responseCode=$(/usr/bin/curl -w "%{http_code}" \
        -H "Authorization: Bearer ${api_token}" \
        "https://${FQDN}/api/v1/auth/invalidate-token" \
        -X POST -s -o /dev/null)

    log "Invalidate token response code: ${responseCode}"

    if [[ "${responseCode}" == "204" ]]; then
        log "Token successfully invalidated"
        tprint "  ✓ Access token invalidated"
        api_token=""
        token_expiration_epoch="0"
        return 0
    elif [[ "${responseCode}" == "401" ]]; then
        log "Token already invalid"
        api_token=""
        token_expiration_epoch="0"
        return 0
    else
        log "WARNING: Unexpected response ${responseCode} when invalidating token"
        return 1
    fi

}


discoverPods()
{

    # Phase 1: discover all distinct jpro-ingress cookie values via cookieless probes
    # against /healthCheck.html (fast/cheap regardless of URL_PATH).
    # Sets the global `cookies` array.
    # Returns: 0 if at least one pod found, 1 otherwise.

    tprint ""
    tprint "Step 1: Discovering pods for ${FQDN}"
    log "Step 1: Pod discovery via jpro-ingress cookie probing"

    integer consecutive_no_new=0
    integer total_probes=0
    local cookie

    while (( consecutive_no_new < POD_DISCOVERY_TRIES )); do
        cookie=$(/usr/bin/curl -sI "https://${FQDN}/healthCheck.html" --max-time 10 2>/dev/null \
            | /usr/bin/grep -i "^set-cookie: jpro-ingress=" \
            | /usr/bin/sed 's/.*jpro-ingress=\([^;]*\).*/\1/' \
            | /usr/bin/tr -d '[:space:]')

        total_probes=$(( total_probes + 1 ))

        if [[ -z "$cookie" ]]; then
            consecutive_no_new=$(( consecutive_no_new + 1 ))
            continue
        fi

        if (( ! ${cookies[(Ie)$cookie]} )); then
            cookies+=("$cookie")
            consecutive_no_new=0
            log "Found pod cookie: ${cookie} (${#cookies} total after ${total_probes} probes)"
            tprint "  ✓ Found pod cookie: ${cookie} (${#cookies} total after ${total_probes} probes)"
        else
            consecutive_no_new=$(( consecutive_no_new + 1 ))
        fi
    done

    if (( ${#cookies} == 0 )); then
        log "ERROR: No jpro-ingress cookies found for ${FQDN}"
        tprint "  ✗ No pods discovered — is '${FQDN}' a valid Jamf Pro Cloud instance?"
        return 1
    fi

    log "Pod discovery complete: ${#cookies} pod(s) found"
    tprint "  → ${#cookies} pod(s) discovered"
    return 0

}


hitAllPods()
{

    # Phase 2: issue an authenticated request against each discovered pod individually.
    # Token is obtained once before this function is called; checkTokenExpiration is called
    # per-pod only as a safety net for large fleets where the token may expire mid-run.
    # Returns: 0 if all pods respond, 1 if any curl call fails outright.

    tprint ""
    tprint "Step 3: Hitting ${#cookies} pod(s) — ${HTTP_METHOD} https://${FQDN}${URL_PATH}"
    log "Step 3: Sending ${HTTP_METHOD} requests to ${#cookies} pod(s)"

    integer pod_num=0
    integer error_count=0
    local cookie
    local result
    local httpCode
    local timeTotal
    local body
    local -a curlArgs

    for cookie in "${cookies[@]}"; do
        pod_num=$(( pod_num + 1 ))

        log "Pod ${pod_num} (cookie: ${cookie})"

        # Safety net: only refresh if genuinely expiring (covers large fleets with short-lived tokens)
        if ! checkTokenExpiration; then
            log "ERROR: Could not refresh token before pod ${pod_num}"
            tprint "  ✗ Pod ${pod_num}: token refresh failed"
            error_count=$(( error_count + 1 ))
            continue
        fi

        tprint ""
        tprint "──────────────────────────────────────────"
        tprint "  Pod ${pod_num}  (cookie: ${cookie})"
        tprint "  ${HTTP_METHOD} https://${FQDN}${URL_PATH}"
        tprint ""

        # Build curl command arguments in an array for clean quoting
        curlArgs=(
            --silent
            --show-error
            --max-time 30
            --request "${HTTP_METHOD}"
            --cookie "jpro-ingress=${cookie}"
            --header "Authorization: Bearer ${api_token}"
            --write-out "\n%{http_code} %{time_total}s"
        )

        curlArgs+=("https://${FQDN}${URL_PATH}")

        result=$(/usr/bin/curl "${curlArgs[@]}" 2>&1) || {
            log "ERROR: curl failed for pod ${pod_num}"
            tprint "  ✗ Pod ${pod_num}: curl error"
            error_count=$(( error_count + 1 ))
            continue
        }

        # Last line is "HTTP_CODE TIME", body is everything before it
        httpCode=$(echo "$result" | /usr/bin/tail -1 | /usr/bin/awk '{print $1}')
        timeTotal=$(echo "$result" | /usr/bin/tail -1 | /usr/bin/awk '{print $2}')
        body=$(echo "$result" | /usr/bin/sed '$d')

        log "Pod ${pod_num} — HTTP ${httpCode} (${timeTotal})"
        [[ -n "$body" ]] && log "Pod ${pod_num} — Response body: ${body}"

        tprint "  HTTP ${httpCode}  (time: ${timeTotal})"
        [[ -n "$body" ]] && tprint "  ${body}"
    done

    tprint ""

    if (( error_count > 0 )); then
        log "WARNING: ${error_count} pod(s) encountered errors"
        return 1
    fi

    return 0

}


mainWorkflow()
{

    # Main script workflow
    # Returns: 0 on success, 1 on failure

    # Step 0: Prompt for API credentials
    tprint "Step 0: Gathering credentials"
    log "Step 0: Prompting for API client credentials"
    if ! promptForCredentials; then
        return 1
    fi

    # Step 1: Discover pods (done before token fetch to avoid burning token lifetime during discovery)
    if ! discoverPods; then
        return 1
    fi

    # Step 2: Obtain bearer token (fetched after discovery so it's fresh for the actual requests)
    tprint ""
    tprint "Step 2: Obtaining API access token"
    log "Step 2: Obtaining API access token"
    if ! getAccessToken; then
        return 1
    fi

    # Step 3: Hit all pods (token checked per-pod as safety net only, not re-fetched unless expiring)
    if ! hitAllPods; then
        invalidateToken
        return 1
    fi

    # Step 4: Clean up
    tprint "Step 4: Cleaning up"
    log "Step 4: Invalidating token"
    invalidateToken

    return 0

}


##########################################################################################
#################################### End functions #######################################
##########################################################################################

##########################################################################################
#################################### Argument Parsing ####################################
##########################################################################################

# Require exactly one argument
if [[ $# -lt 1 ]]; then
    usage
fi

FQDN="$1"

##########################################################################################
#################################### Main Execution ######################################
##########################################################################################

setup
start

if mainWorkflow; then
    returncode=0
else
    returncode=1
fi

finish
exit "${returncode:-0}"