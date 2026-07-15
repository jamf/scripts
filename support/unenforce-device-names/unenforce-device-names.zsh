#!/bin/zsh --no-rcs

##########################################################################################
#
# Copyright (c) 2026, JAMF Software, LLC.  All rights reserved.
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
# This script sets enforceName=false on every mobile device in a specified Smart Group. Nothing else.
# This simply unlocks the name field so that it *can* be changed by another integration or automation.
# It does not change the name itself, and it does not prevent the name from being changed again in the future.
#
# Authenticates using OAuth2 client credentials, pulls Smart Group membership from the
# Classic API (JSON), then PATCHes /api/v2/mobile-devices/{id} with {"enforceName": false}
# for each member.
#
# DEPLOYMENT INSTRUCTIONS:
# - Standalone interactive zsh tool; run from an admin's machine.
# - Usage:
#     ./unenforce-device-names.zsh <smartGroupID>
# - Credentials (Jamf Pro URL, API Client ID, API Client Secret) are prompted for
#   interactively; the secret is read silently.
#
# API CLIENT PRIVILEGES REQUIRED:
# - Read Mobile Device Groups
# - Read Mobile Devices
# - Update Mobile Devices
#
##########################################################################################
#
# CHANGE LOG
# 1.0 - Created - bjulian
#
##########################################################################################

##########################################################################################
################################### Global Variables ####################################
##########################################################################################

scriptExtension=${0##*.}
swTitle=$(/usr/bin/basename "$0" ".${scriptExtension}")
ver="1.0"

groupID="${1:-}"

jamfURL=""
clientID=""
clientSecret=""
access_token=""
token_expiration_epoch=0

successCount=0
failCount=0

returncode=0

logDir="${HOME}/.jamf_name_enforcement/logs"
logFile="${logDir}/${swTitle}_$(date '+%Y%m%d_%H%M%S').log"

##########################################################################################
##################################### Functions ##########################################
##########################################################################################

tprint()
{
    print "$@" >&3
}

log()
{
    print "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${logFile}" >/dev/null
}

trim()
{
    local var="$1"
    var="${var#"${var%%[^[:space:]]*}"}"
    var="${var%"${var##*[^[:space:]]}"}"
    print -r -- "${var}"
}

promptForCredentials()
{
    tprint -n "Jamf Pro URL (e.g. https://yourinstance.jamfcloud.com): "
    read -r jamfURL
    jamfURL=$(trim "${jamfURL}")
    jamfURL="${jamfURL%/}"

    tprint -n "API Client ID: "
    read -r clientID
    clientID=$(trim "${clientID}")

    tprint -n "API Client Secret: "
    read -s clientSecret
    clientSecret=$(trim "${clientSecret}")
    tprint ""

    if [[ -z "${jamfURL}" || -z "${clientID}" || -z "${clientSecret}" ]]; then
        tprint "ERROR: Jamf Pro URL, Client ID, and Client Secret are all required."
        log "ERROR: Missing one or more required credential inputs"
        return 1
    fi

    return 0
}

getAccessToken()
{
    local response curlErr curlExit
    curlErr="/tmp/${swTitle}_curlerr_$$.txt"
    response=$(/usr/bin/curl -s -X POST "${jamfURL}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${clientID}" \
        --data-urlencode "client_secret=${clientSecret}" \
       --data-urlencode "grant_type=client_credentials" \
       2>"${curlErr}")
   curlExit=$?

   if [[ ${curlExit} -ne 0 ]]; then
       tprint "ERROR: curl could not reach ${jamfURL} (exit code ${curlExit})."
       tprint "  $(cat "${curlErr}")"
       log "ERROR: curl exit ${curlExit} contacting ${jamfURL}/api/oauth/token: $(cat "${curlErr}")"
       rm -f "${curlErr}"
       return 1
   fi
   rm -f "${curlErr}"

    access_token=$(print -r -- "${response}" | /usr/bin/plutil -extract access_token raw -o - -- - 2>/dev/null)
    local expires_in
    expires_in=$(print -r -- "${response}" | /usr/bin/plutil -extract expires_in raw -o - -- - 2>/dev/null)

    if [[ -z "${access_token}" ]]; then
       if [[ -z "${response}" ]]; then
           tprint "ERROR: Server returned an empty response (connection reached ${jamfURL} but no body came back)."
           log "ERROR: Empty response body from ${jamfURL}/api/oauth/token"
       else
           tprint "ERROR: Failed to obtain access token. Server said:"
           tprint "  ${response}"
           log "ERROR: Token response: ${response}"
       fi
       return 1
    fi

    token_expiration_epoch=$(( $(date +%s) + ${expires_in:-300} - 30 ))
    log "Obtained access token"
    return 0
}

checkTokenExpiration()
{
    if [[ $(date +%s) -ge ${token_expiration_epoch} ]]; then
        log "Token nearing expiration — refreshing"
        getAccessToken
    fi
    return 0
}

invalidateToken()
{
    if [[ -n "${access_token}" ]]; then
        /usr/bin/curl -s -X POST "${jamfURL}/api/v1/auth/invalidate-token" \
            --header "Authorization: Bearer ${access_token}" >/dev/null
        log "Invalidated access token"
    fi
    return 0
}

unenforceGroupNames()
{
    local membersJson devID devName httpCode i=0 total

    membersJson="/tmp/${swTitle}_group_${groupID}_$$.json"

    tprint "Fetching membership for Smart Group ID ${groupID}..."
    log "Fetching Smart Group ${groupID} membership"

    /usr/bin/curl -s "${jamfURL}/JSSResource/mobiledevicegroups/id/${groupID}" \
        --header "Authorization: Bearer ${access_token}" \
        --header "Accept: application/json" \
        -o "${membersJson}"

    if [[ ! -s "${membersJson}" ]]; then
        tprint "ERROR: No response retrieving Smart Group ${groupID}."
        log "ERROR: Empty response fetching group ${groupID}"
        rm -f "${membersJson}"
        return 1
    fi

    while true; do
        devID=$(/usr/bin/plutil -extract "mobile_device_group.mobile_devices.${i}.id" raw -o - -- "${membersJson}" 2>/dev/null)
        [[ -z "${devID}" ]] && break
        devName=$(/usr/bin/plutil -extract "mobile_device_group.mobile_devices.${i}.name" raw -o - -- "${membersJson}" 2>/dev/null)

        checkTokenExpiration

        httpCode=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" -X PATCH \
            "${jamfURL}/api/v2/mobile-devices/${devID}" \
            --header "Authorization: Bearer ${access_token}" \
            --header "Content-Type: application/json" \
            --data '{"enforceName": false}')

        if [[ "${httpCode}" == "200" || "${httpCode}" == "204" ]]; then
            log "OK   - device ${devID} (${devName}) enforceName=false (HTTP ${httpCode})"
            ((successCount++))
        else
            tprint "  ⚠ device ${devID} (${devName}) failed (HTTP ${httpCode})"
            log "FAIL - device ${devID} (${devName}) enforceName=false (HTTP ${httpCode})"
            ((failCount++))
        fi

        ((i++))
    done

    rm -f "${membersJson}"
    total=${i}

    if [[ "${total}" -eq 0 ]]; then
        tprint "ERROR: Smart Group ${groupID} returned zero members."
        log "ERROR: Zero members in group ${groupID}"
        return 1
    fi

    tprint ""
    tprint "Processed ${total} devices — ${successCount} succeeded, ${failCount} failed."
    log "Result: ${total} processed, ${successCount} succeeded, ${failCount} failed"

    [[ "${failCount}" -gt 0 ]] && return 1
    return 0
}

mainWorkflow()
{
    tprint "Step 1: Gathering credentials"
    log "Step 1: Prompting for API client credentials"
    if ! promptForCredentials; then
        return 1
    fi

    tprint ""
    tprint "Step 2: Obtaining API access token"
    log "Step 2: Obtaining API access token"
    if ! getAccessToken; then
        return 1
    fi

    tprint ""
    tprint "Step 3: Un-enforcing device names for Smart Group ${groupID}"
    log "Step 3: unenforcing names for group ${groupID}"
    if ! unenforceGroupNames; then
        invalidateToken
        return 1
    fi

    tprint ""
    tprint "Step 4: Cleaning up API token"
    log "Step 4: Invalidating token"
    invalidateToken

    return 0
}

setup()
{
    umask 077
    mkdir -p "${logDir}"
    chmod 700 "${logDir}"
    touch "${logFile}"
    chmod 600 "${logFile}"

    if [[ -z "${groupID}" ]]; then
        tprint "ERROR: Smart Group ID is required."
        tprint "Usage: ${0} <smartGroupID>"
        returncode=1
        return 1
    fi

    return 0
}

start()
{
    tprint "=========================================================="
    tprint " ${swTitle} v${ver} — $(date '+%Y-%m-%d %H:%M:%S')"
    tprint " Smart Group ID: ${groupID}"
    tprint "=========================================================="
    log "===== START: ${swTitle} v${ver} — group=${groupID} ====="
}

finish()
{
    tprint "=========================================================="
    tprint " Finished: $(date '+%Y-%m-%d %H:%M:%S')  Result: $([[ ${returncode} -eq 0 ]] && echo SUCCESS || echo FAILED)"
    tprint " Log: ${logFile}"
    tprint "=========================================================="
    log "===== FINISH: result=$([[ ${returncode} -eq 0 ]] && echo SUCCESS || echo FAILED) ====="
}

##########################################################################################
################################### End functions ########################################
##########################################################################################

##########################################################################################
#################################### Main Execution ######################################
##########################################################################################

exec 3>&1

setup
if [[ ${returncode} -ne 0 ]]; then
    exit "${returncode}"
fi

start
if mainWorkflow; then
    returncode=0
else
    returncode=1
fi
finish

exit "${returncode}"