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
# This script is designed to be run locally on a Mac via a Jamf Pro policy. Its purpose 
# is to renew its own MDM profile via the Jamf Pro API "/api/v1/mdm/renew-profile" 
# endpoint.
#
# DEPLOYMENT INSTRUCTIONS:
# - Upload this script to Jamf Pro
# - Create a policy with this script
# - Configure script parameters 4 and 5 (required):
#   Parameter 4: API Client ID (required)
#   Parameter 5: API Client Secret (required)
#   Parameter 6: Jamf Pro URL (optional - auto-detects if not provided)
#
# API CLIENT PRIVILEGES REQUIRED:
# - Read Computers
# - Send Command to Renew MDM Profile
#
##########################################################################################
#
# CHANGE LOG
#
# Version 2.0 - 2026-02-05
#   - Refactored to follow Jamf template style guidelines
#   - Added auto-detection of Jamf Pro URL from device enrollment
#   - Implemented retry logic for API calls
#   - Enhanced error handling and validation
#   - Fixed token expiration and UDID parsing issues
#   - Added comprehensive logging with timestamps
#
# Version 1.0 - Initial release
#   - Basic MDM profile renewal functionality
#
##########################################################################################

##########################################################################################
################################### Global Variables #####################################
##########################################################################################

# Script metadata
scriptExtension=${0##*.}
swTitle=$(/usr/bin/basename "$0" ."${scriptExtension}")
ver="2.0"

# Log directory and file
debugDir="/var/log/managed"
debugFile="${debugDir}/${swTitle}.log"

# Exit status
returncode=0

# API Token variables
api_token=""
token_expiration_epoch=0

# Jamf Pro API Client Credentials (from script parameters)
client_id="${4:-your-client-id}"
client_secret="${5:-yourClientSecret}"

# Jamf Pro Server URL
url=""

# Client Computer variables
machineUUID=""
computerUDID=""

# Retry configuration
max_retries=3
retry_delay=5

##########################################################################################
#################################### Start functions #####################################
##########################################################################################

setup()
{
    # Initialize logging and validate prerequisites
    
    # Create log directory if it doesn't exist
    if [[ ! -d "${debugDir}" ]]; then
        /bin/mkdir -p "${debugDir}"
        /bin/chmod -R 755 "${debugDir}"
    fi
    
    # Create log file if it doesn't exist
    if [[ ! -f "${debugFile}" ]]; then
        /usr/bin/touch "${debugFile}"
    fi
    
    # Redirect all output to both console and log file
    exec > >(/usr/bin/tee -a "${debugFile}") 2>&1
    
    # Validate API credentials are provided
    if [[ "$client_id" == "your-client-id" ]] || [[ "$client_secret" == "yourClientSecret" ]]; then
        echo "ERROR: API credentials not configured. Please set script parameters 4 and 5."
        returncode=1
        return 1
    fi
    
    # Get hardware UUID
    machineUUID=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk '/IOPlatformUUID/ { gsub(/"/,"",$3); print $3; }')
    
    if [[ -z "$machineUUID" ]]; then
        log "ERROR: Could not determine hardware UUID of this Mac"
        returncode=1
        return 1
    fi
    
    # Detect or validate Jamf Pro URL
    if [[ -n "${6}" ]]; then
        url="${6}"
        log "Using Jamf Pro URL from script parameter: ${url}"
    else
        url=$(getJamfProURL)
        if [[ -n "$url" ]]; then
            log "Auto-detected Jamf Pro URL from enrollment: ${url}"
        else
            log "ERROR: Could not determine Jamf Pro URL"
            log "Please either:"
            log "  - Set script parameter 6 with your Jamf Pro URL, or"
            log "  - Ensure device is properly enrolled with Jamf Pro"
            returncode=1
            return 1
        fi
    fi
    
    return 0
}

start()
{
    # Log script start with metadata
    
    echo ""
    echo "##########################################################################################"
    echo "###########################################-START-#########################################"
    echo "##########################################################################################"
    echo ""
    echo "Jamf Pro MDM Profile Renewal"
    echo "Running ${swTitle} Version ${ver}"
    echo ""
    echo "Started: $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    echo "Jamf Pro URL: ${url}"
    echo "Hardware UUID: ${machineUUID}"
    echo ""
}

finish()
{
    # Log script completion
    
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
    echo "############################################-END-##########################################"
    echo "##########################################################################################"
    echo ""
}

log()
{
    # Standardized logging with timestamps
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

getJamfProURL()
{
    # Detect Jamf Pro URL from device enrollment
    # Returns: Jamf Pro URL string or empty if not found
    
    # Method 1: Read from jamf binary preferences (most reliable)
    local jss_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null)
    
    if [[ -n "$jss_url" ]]; then
        jss_url="${jss_url%/}"
        echo "$jss_url"
        return 0
    fi
    
    # Method 2: Parse from jamf binary command (fallback)
    jss_url=$(/usr/local/bin/jamf checkJSSConnection 2>/dev/null | /usr/bin/awk -F'https://' '/Checking/ {print "https://"$2}' | /usr/bin/awk '{print $1}')
    
    if [[ -n "$jss_url" ]]; then
        jss_url="${jss_url%/}"
        echo "$jss_url"
        return 0
    fi
    
    return 1
}

getAccessToken()
{
    # Fetch a new bearer token for Jamf Pro API authentication
    # Returns: 0 on success, 1 on failure
    
    log "Requesting new access token from Jamf Pro API"
    
    local response=$(curl --silent --location --request POST "${url}/api/v1/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${client_id}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${client_secret}")
    
    # Extract token and expiration from JSON response
    api_token=$(echo "$response" | /usr/bin/plutil -extract access_token raw - 2>/dev/null)
    local token_expires_in=$(echo "$response" | /usr/bin/plutil -extract expires_in raw - 2>/dev/null)
    
    # Validate token was received
    if [[ -z "$api_token" ]] || [[ "$api_token" == "null" ]]; then
        log "ERROR: Failed to obtain access token"
        log "Response: ${response}"
        return 1
    fi
    
    local current_epoch=$(date +%s)
    token_expiration_epoch=$((current_epoch + token_expires_in - 60))
    
    log "Access token obtained successfully (expires in ${token_expires_in} seconds)"
    return 0
}

checkTokenExpiration()
{
    # Check if current token is still valid, refresh if needed
    # Returns: 0 on success, 1 on failure
    
    local current_epoch=$(date +%s)
    
    # Add 60 second buffer to avoid edge case failures
    if [[ -n "$api_token" ]] && [[ $token_expiration_epoch -gt $((current_epoch + 60)) ]]; then
        log "Token valid until epoch: ${token_expiration_epoch}"
        return 0
    else
        log "Token expired or expiring soon, fetching new token"
        getAccessToken
        return $?
    fi
}

invalidateToken()
{
    # Invalidate the current access token
    # Returns: 0 on success, 1 on failure
    
    if [[ -z "$api_token" ]]; then
        log "No token to invalidate"
        return 0
    fi
    
    log "Invalidating access token"
    local responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${api_token}" \
        "${url}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)
    
    if [[ ${responseCode} == 204 ]]; then
        log "Token successfully invalidated"
        api_token=""
        token_expiration_epoch="0"
        return 0
    elif [[ ${responseCode} == 401 ]]; then
        log "Token already invalid"
        api_token=""
        token_expiration_epoch="0"
        return 0
    else
        log "WARNING: Unexpected response code ${responseCode} when invalidating token"
        return 1
    fi
}

GetJamfProUDID()
{
    # Look up computer UDID in Jamf Pro using hardware UUID
    # Outputs: Computer UDID to stdout
    # Returns: 0 on success, 1 on failure
    
    # Send logs to stderr so they don't pollute the returned UDID value
    log "Looking up computer UDID in Jamf Pro for hardware UUID: ${machineUUID}" >&2
    
    # Use Classic API - direct lookup by hardware UUID
    local response=$(/usr/bin/curl -sf \
        --header "Authorization: Bearer ${api_token}" \
        "${url}/JSSResource/computers/udid/${machineUUID}" \
        -H "accept: application/xml" 2>/dev/null)
    
    if [[ -n "$response" ]]; then
        local udid=$(/usr/bin/xmllint --xpath "/computer/general/udid/text()" - 2>/dev/null <<< "$response")
        
        if [[ -n "$udid" ]] && [[ "$udid" != "null" ]]; then
            log "Successfully retrieved UDID from Jamf Pro" >&2
            # Only output the UDID to stdout
            echo "$udid"
            return 0
        fi
    fi
    
    log "ERROR: Could not retrieve computer UDID from Jamf Pro" >&2
    return 1
}

validateUDID()
{
    # Validate that a string is a properly formatted UUID
    # Args: $1 - UDID string to validate
    # Returns: 0 if valid, 1 if invalid
    
    local udid="$1"
    
    # UUID format: 8-4-4-4-12 hexadecimal characters (uppercase)
    if [[ "$udid" =~ ^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$ ]]; then
        return 0
    else
        return 1
    fi
}

RenewMDMProfile()
{
    # Send MDM profile renewal command to Jamf Pro
    # Returns: 0 on success, 1 on failure
    
    log "Sending MDM profile renewal command for UDID: ${computerUDID}"
    
    # Make the API call and capture both response body and HTTP code
    local response=$(/usr/bin/curl -s -w "\n%{http_code}" -X POST \
        "${url}/api/v1/mdm/renew-profile" \
        -H "accept: application/json" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" \
        -d "{\"udids\":[\"${computerUDID}\"]}")
    
    # Parse response
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    # Check for success
    if [[ ${http_code} == 200 ]] || [[ ${http_code} == 201 ]]; then
        log "MDM profile renewal command sent successfully (HTTP ${http_code})"
        return 0
    else
        log "ERROR: API returned status ${http_code}"
        if [[ -n "$body" ]]; then
            log "Response body: ${body}"
        fi
        return 1
    fi
}

RenewMDMProfileWithRetry()
{
    # Attempt MDM profile renewal with retry logic
    # Returns: 0 on success, 1 on failure after all retries
    
    local attempt=1
    
    while [[ $attempt -le $max_retries ]]; do
        log "Renewal attempt ${attempt} of ${max_retries}"
        
        if RenewMDMProfile; then
            return 0
        fi
        
        if [[ $attempt -lt $max_retries ]]; then
            log "Retrying in ${retry_delay} seconds..."
            sleep $retry_delay
        fi
        
        ((attempt++))
    done
    
    log "ERROR: All retry attempts exhausted"
    return 1
}

mainWorkflow()
{
    # Main script workflow
    # Returns: 0 on success, 1 on failure
    
    # Step 1: Obtain API access token
    log "Step 1: Obtaining API access token"
    if ! getAccessToken; then
        log "ERROR: Failed to obtain access token"
        return 1
    fi
    
    # Step 2: Look up computer UDID in Jamf Pro
    log "Step 2: Looking up computer UDID in Jamf Pro"
    computerUDID=$(GetJamfProUDID)
    
    # Verify UDID was retrieved
    if [[ -z "$computerUDID" ]]; then
        log "ERROR: Could not retrieve computer UDID from Jamf Pro"
        log "Possible causes:"
        log "  - Computer not enrolled in Jamf Pro"
        log "  - Hardware UUID mismatch"
        log "  - API client lacks 'Read Computers' privilege"
        return 1
    fi
    
    # Verify UDID format is valid
    if ! validateUDID "$computerUDID"; then
        log "ERROR: Invalid UDID format: ${computerUDID}"
        log "Expected format: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        return 1
    fi
    
    log "Found valid computer UDID: ${computerUDID}"
    
    # Step 3: Initiate MDM profile renewal
    log "Step 3: Initiating MDM profile renewal"
    if RenewMDMProfileWithRetry; then
        log "SUCCESS: MDM profile renewal command sent successfully"
        log "The MDM profile will be renewed shortly"
    else
        log "ERROR: MDM profile renewal failed after ${max_retries} attempts"
        log "Possible causes:"
        log "  - Network connectivity issues"
        log "  - API client lacks 'Send Command to Renew MDM Profile' privilege"
        log "  - MDM enrollment issue on this device"
        return 1
    fi
    
    # Step 4: Clean up API token
    log "Step 4: Cleaning up API token"
    invalidateToken
    
    return 0
}

##########################################################################################
#################################### End functions #######################################
##########################################################################################

##########################################################################################
#################################### Main Execution ######################################
##########################################################################################

setup
if [[ $returncode -ne 0 ]]; then
    finish
    exit "$returncode"
fi

start
if mainWorkflow; then
    returncode=0
else
    returncode=1
fi
finish

exit "$returncode"
