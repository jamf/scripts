#!/bin/bash

###########################################################################################################################
#
# Copyright 2025, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
#
###########################################################################################################################
#
# Description:
# 
# A script to help re-deploy the Jamf Pro Framework to a Smart Computer Group. 
# An existing Smart Computer Group can be can used or a new one can be created. 
# The new Smart Computer Group will use the number of days since the last inventory update as criteria. 
# A prompt will ask for the number of days to use for the criteria.
#
# This script uses Bart Reardon's swiftDialog for user dialogs.
# https://github.com/bartreardon/swiftDialog
#
# swiftDialog must be installed before running this script.
#
############################################################################################################################
#
# Created by Sebastien Del Saz Alvarez on 29 August 2025
#
###########################################################################################################################

# Paths to required binaries and script resources
dialog_path="/usr/local/bin/dialog"
curl_path="/usr/bin/curl"
plutil_path="/usr/bin/plutil"
log_file="/Users/Shared/Framework-Fixer.log"

# Create the log_file
touch "${log_file}"

# Dialog variables
message_font="size=18,name=HelveticaNeue"
title_font="weight=bold,size=30,name=HelveticaNeue-Bold"
icon="https://raw.githubusercontent.com/jamf/scripts/refs/heads/main/services/Framework-Fixer/Images/Framework-Fixer-icon.png"

#######################################################################################################
# Check if swiftDialog is installed. if not, inform the user of the prerequisites
#######################################################################################################
echo "######################################START LOGGING#############################################
$(
date '+%Y-%m-%d %H:%M:%S') INFO: Checking if swiftDialog is installed" >> "${log_file}"
if [[ -e "${dialog_path}" ]]
then
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: swiftDialog is already installed" >> "${log_file}"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: swiftDialog not installed! Please install swiftDialog." >> "${log_file}"
    osascript <<'EOF'
    set userChoice to button returned of (display alert ¬
    "swiftDialog Missing" ¬
    message "swiftDialog is not installed. This tool is a requirement for this script. Would you like to download the latest version?" ¬
    buttons {"Cancel", "Download"} ¬
    as critical)
    
    if userChoice is "Download" then
    open location "https://github.com/swiftDialog/swiftDialog/releases/latest"
    else
    end if
EOF
    exit 1
fi


#######################################################################################################
#  functions
#######################################################################################################
# Check http response
check_response() {
    local http_code
    http_code=$("${curl_path}" -s -o /dev/null -w "%{http_code}" "$@")
    
    if [[ "${http_code}" =~ ^(200|201|202|204)$ ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Command successfully sent: HTTP code: ${http_code}" >> "${log_file}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Command failed with HTTP error ${http_code}" >> "${log_file}"
        case "${http_code}" in
            400) echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Bad Request" >> "${log_file}" ;;
            401) echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unauthorized - check your credentials." >> "${log_file}" ;;
            403) echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Forbidden - Insufficient privileges." >> "${log_file}" ;;
            404) echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Not Found - resource does not exist." >> "${log_file}" ;;
            409) echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Conflict - resource may already exist." >> "${log_file}" ;;
            500) echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Server Error - try again later." >> "${log_file}" ;;
            *)   echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unexpected HTTP response: ${http_code}" >> "${log_file}" ;;
        esac
    fi
    echo "${http_code}"
}


#######################################################################################################
# Prompt functions
#######################################################################################################
# Prompt to choose Authentication Method
auth_method_prompt() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Asking to select an authentication method" >> "${log_file}"

    if ! auth_method=$(
        "${dialog_path}" \
            --title "Framework Fixer" \
            --message 'Welcome!

Please select a method to authenticate to Jamf Pro. Click on "Required Privileges" for more information.' \
            --radio \
            --selecttitle "Please select an option",radio \
            --selectvalues "User Account & Password, API Client & Secret" \
            --icon "${icon}" \
            --alignment "left" \
            --button2 \
            --messagefont "${message_font}" \
            --titlefont "${title_font}" \
            --infobuttontext "Required Privileges" \
            --infobuttonaction "https://github.com/jamf/scripts/services/Framework-Fixer/?tab=readme-ov-file#requirements" \
            --small \
            --height "450"
    )
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: User Cancelled" >> "${log_file}"
        invalidate_token
        exit 0
    fi
    auth_selection=$(echo "${auth_method}" | grep "\"Please select an option\" : " | awk -F '"' '{print $4}')
    if [[ ${auth_selection} == "User Account & Password" ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Selected authentication method: User Account & Password" >> "${log_file}"
        username_label="User Name"
        password_label="Password"
        auth_method="user_creds"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Selected authentication method: API Client & Secret" >> "${log_file}"
        username_label="Client ID"
        password_label="Client Secret"
        auth_method="client_secret"
    fi
}

# Prompt for User Account and Password
credential_prompt() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Prompting for credentials and server URL" >> "${log_file}"
    if server_details=$(
        "${dialog_path}" \
            --title "Framework Fixer" \
            --message "Please enter your Jamf Pro details below:" \
            --textfield "Jamf Pro URL, required" \
            --textfield "${username_label}, required" \
            --textfield "${password_label}, secure, required" \
            --icon "${icon}" \
            --alignment "left" \
            --small \
            --button2 \
            --messagefont "${message_font}" \
            --titlefont "${title_font}" \
            --height "450" \
            --json
    )
    then
        jamf_pro_url=$(echo "${server_details}" | "${plutil_path}" -extract "Jamf Pro URL" xml1 -o - - | xmllint --xpath "string(//string)" -)
        username=$(echo "${server_details}" | "${plutil_path}" -extract "${username_label}" xml1 -o - - | xmllint --xpath "string(//string)" -)
        api_password=$(echo "${server_details}" | "${plutil_path}" -extract "${password_label}" xml1 -o - - | xmllint --xpath "string(//string)" -)
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: User Cancelled" >> "${log_file}"
        exit 0
    fi
    if [[ ${jamf_pro_url} != *"https://"* ]]
    then 
        jamf_pro_url="https://${jamf_pro_url}"
    fi
}

# Prompt explaining there was an issue with the server details/credentials
invalid_credentials_prompt() {
    "${dialog_path}" \
        --title "Framework Fixer" \
        --message "Oops! We were unable to validate the provided URL or credentials. Please make sure that the server is reachable and that the server URL and credentials are correct." \
        --icon "${icon}" \
        --overlayicon "caution" \
        --alignment "left" \
        --small \
        --messagefont "${message_font}" \
        --titlefont "${title_font}" \
        --button1text "OK" \
        --height "450"
}

# Prompt to choose new or existing group
group_option_prompt() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Prompting to choose between new group or existing group" >> "${log_file}"
    if group_options=$(
        "${dialog_path}" \
            --title "Framework Fixer" \
            --message "Would you like to create a Smart Computer Group to redeploy the Jamf Management Framework to?" \
            --radio "group_selection" \
            --selecttitle "Please select an option",radio \
            --selectvalues "I already have a Smart Computer Group, Please create a Smart Computer Group" \
            --icon "${icon}" \
            --alignment "left" \
            --button2 \
            --messagefont "${message_font}" \
            --titlefont "${title_font}" \
            --small \
            --height "450"
    )
    then
        group_selection=$(echo "${group_options}" | grep "\"Please select an option\" : " | awk -F '"' '{print $4}')
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: User Cancelled" >> "${log_file}"
        invalidate_token
        exit 0
    fi

    if [[ "${group_selection}" == "Please create a Smart Computer Group" ]]
    then
        # Prompt for number of days since last Inventory Update
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: New group workflow selected. Prompting for number of days since last Inventory Update" >> "${log_file}"
        days_prompt
    else
        # Prompt to select an existing group
        group_name_prompt
    fi
}

# Prompt for group selection
group_name_prompt() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Existing group workflow selected." >> "${log_file}"
    
    # Initial check
    http_code=$(check_response -X GET -H "Authorization: Bearer ${bearer_token}" "${jamf_pro_url}/api/v2/computer-groups/smart-groups")
    
    if ! echo "${http_code}" | grep -Eq '^(200|201|202|204)$'; then
        error_prompt
    fi
    
    # Collect all group data
    page=0
    page_size=100
    tmp_groups="$(mktemp)"
    echo "[]" > "${tmp_groups}"
    
    while : ; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Fetching page ${page} of Smart Computer Groups" >> "${log_file}"
        
        page_response=$("${curl_path}" -s -H "Authorization: Bearer ${bearer_token}" "${jamf_pro_url}/api/v2/computer-groups/smart-groups?page=${page}&page-size=${page_size}&sort=name:asc")
        
        echo "${page_response}" \
        | jq '[.results[].name]' > /tmp/page_groups.json
        
        jq -s 'add' "${tmp_groups}" /tmp/page_groups.json > "${tmp_groups}.new" \
        && mv "${tmp_groups}.new" "${tmp_groups}"
        
        total_count=$(echo "${page_response}" | jq '.totalCount')
        
        current_count=$(( (page + 1) * page_size ))
        [ "${current_count}" -ge "${total_count}" ] && break
        
        page=$((page + 1))
    done
    
    if [ "$(jq 'length' "${tmp_groups}")" -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: No Smart Computer Groups found" >> "${log_file}"
        rm -f "${tmp_groups}"
        error_prompt
    fi
    
    # SwiftDialog JSON
    dialog_json="$(mktemp)"
    
    jq -n \
    --arg title "Framework Fixer" \
    --arg message "Choose a Smart Computer Group from the list:" \
    --arg icon "${icon}" \
    --slurpfile values "${tmp_groups}" \
    '{
title: $title,
message: $message,
icon: $icon,
alignment: "left",
small: true,
button1text: "Select",
button2text: "Back",
selecttitle: "Smart Computer Group",
selectvalues: $values[0]
}' > "${dialog_json}"
    
    dialog_output=$(
"${dialog_path}" \
--json \
--jsonfile "${dialog_json}"
) || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: User clicked Back" >> "${log_file}"
        rm -f "${tmp_groups}" "${dialog_json}"
        group_option_prompt
        return
    }
    
    group_name=$(echo "${dialog_output}" | jq -r '.SelectedOption')
    group_name2=$(printf '%s' "${group_name}" | jq -sRr @uri)
    
    rm -f "${tmp_groups}" "${dialog_json}" /tmp/page_groups.json
}

# Prompt for number of days since last Inventory Update
days_prompt() {
    if days=$(
        "${dialog_path}" \
            --title "Framework Fixer" \
            --message "OK, we will create a Smart Computer Group based on the number of days since the last Inventory Update. Please enter the number of days." \
            --textfield "Number of days, regex=^[0-9]+$, regexerror=Input must be a number, required: true" \
            --icon "${icon}" \
            --alignment "left" \
            --small \
            --button2 \
            --button2text "Back" \
            --messagefont "${message_font}" \
            --titlefont "${title_font}" \
            --height "450" \
            --json
    )
    then
        days=$(echo "$days" | grep "\"Number of days\" : " | awk -F '"' '{print $4}')
        new_group_prompt
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: User clicked on 'Back'" >> "${log_file}"
        group_option_prompt
    fi
}

# Request the name of the Smart Computer Group to be created
new_group_prompt() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Requesting the name for the new Smart Computer Group" >> "${log_file}"
    if group_name=$(
        "${dialog_path}" \
            --title "Framework Fixer" \
            --message "Please enter a name for the new Smart Computer Group." \
            --textfield "Group Name, required" \
            --icon "${icon}" \
            --alignment "left" \
            --small \
            --button2 \
            --messagefont "${message_font}" \
            --titlefont "${title_font}" \
            --height "450" \
            --json
    )
    then
        group_name=$(echo "${group_name}" | "${plutil_path}" -extract "Group Name" xml1 -o - - | xmllint --xpath "string(//string)" -)
        # Replace spaces with %20 for API call
        group_name2=$(echo "${group_name}" | sed 's/ /%20/g')
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: User Cancelled" >> "${log_file}"
        invalidate_token
        exit 0
    fi
    # Check to make sure we are able to verify the existence of the group
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Checking if a group called ${group_name} already exists" >> "${log_file}"
    response=$("${curl_path}" -s -w "\n%{http_code}" -X 'GET' "${jamf_pro_url}/api/v2/computer-groups/smart-groups?page=0&page-size=100&sort=id%3Aasc&filter=name%3D%3D%22${group_name2}%22" -H "accept: application/json" -H "Authorization: Bearer ${bearer_token}" -b "${ap_balance_id}")
                
    # Split into body and HTTP code
    http_code=$(echo "$response" | tail -n1)
    group_check=$(echo "$response" | sed '$d')

    # Check if the previous check was successful
    if [[ ${http_code} =~ ^(200|201|202|204)$ ]]
    then
        count=$(printf '%s\n' "$group_check" | tr -d '\n' | sed -n 's/.*"totalCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        # If not, present an error message  
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Could not check if a group called ${group_name} already exists" >> "${log_file}"
        error_prompt
        invalidate_token
        exit 1
    fi
    
    if [[ "$count" -eq 1 ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: There is already a Smart Computer Group named ${group_name}" >> "$log_file"
        group_exists
    else
        create_group
    fi
}

# Prompt to indicate there are no members in the Smart Computer Group
no_members_prompt() {
    "${dialog_path}" \
        --title "Framework Fixer" \
        --message "There are 0 members in this Smart Computer Group.  No action required." \
        --icon "${icon}" \
        --alignment "left" \
        --small \
        --messagefont "${message_font}" \
        --titlefont "${title_font}" \
        --button1text "OK" \
        --height "450"
    invalidate_token
}

# Show number of devices in the Smart Computer Group and ask if we should remediate
remediation_prompt() {
    remediation_check=$(
        "${dialog_path}" \
        --title "Framework Fixer" \
        --message "There are ${member_count} members in the Smart Computer Group.  Would you like to redeploy the Jamf Management Framework on all computers in this group?" \
        --icon "${icon}" \
        --alignment "left" \
        --small \
        --button1text "No" \
        --button2text "Yes" \
        --messagefont "${message_font}" \
        --titlefont "${title_font}" \
        --height "450" \
        --json
    )
    if [ $? == 2 ]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Remediation choice: yes" >> "${log_file}"
        remediation_check="Yes"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Remediation choice: No. Exiting." >> "${log_file}"
        invalidate_token
        exit 0
    fi
}

redeployment_prompt() {
    # Create a command file (needed to close the dialog later if needed)
    command_file="/Users/Shared/dialogIndeterminate.txt"
    : > "$command_file"
    
    ${dialog_path} \
    --title "Framework Fixer" \
    --message "We're working on it! This can take a while depending on how many computers are in the Smart Computer Group" \
    --icon "${icon}" \
    --alignment "left" \
    --small \
    --messagefont "${message_font}" \
    --titlefont "${title_font}" \
    --button1text "Cancel" \
    --progress --indeterminate \
    --commandfile "${command_file}" & sleep 0.1
    
    dialog_pid=$!
}

create_group() {
    # JSON payload for the smart group
    read -r -d '' json_payload << EOM
    {
    "name": "${group_name}",
    "criteria": [
            {
            "name": "Last Inventory Update",
            "priority": 0,
            "andOr": "and",
            "searchType": "more than x days ago",
            "value": "${days}",
            "openingParen": false,
            "closingParen": false
            }
    ],
    "siteId": "-1"
    }
EOM

    # Create the Smart Computer Group
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Creating group called ${group_name}" >> "${log_file}"
    group_creation=$(check_response -X 'POST' "${jamf_pro_url}/api/v2/computer-groups/smart-groups" -H "accept: application/json" -H "Authorization: Bearer ${bearer_token}" -H "Content-Type: application/json" -d "${json_payload}" -b "${ap_balance_id}")
    if [[ $group_creation =~ ^(200|201|202|204)$ ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Group called ${group_name} successfully created" >> "${log_file}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Group creation failed" >> "${log_file}"
        error_prompt
        invalidate_token
        exit 1
    fi
}

error_prompt() {
    if "${dialog_path}" \
        --title "Framework Fixer" \
        --message "Oops! An error occurred. Please check ${log_file} for more details" \
        --icon "${icon}" \
        --overlayicon "caution" \
        --alignment "left" \
        --small \
        --messagefont "${message_font}" \
        --titlefont "${title_font}" \
        --button1text "OK" \
        --height "450"
    then
        invalidate_token
        exit 1
    fi
}

# End prompt
done_prompt() {
    "${dialog_path}" \
        --title "Framework Fixer" \
        --message "We're done!\n\nThe command to redeploy the Jamf Management Framework has been sent to all members of the Smart Computer Group." \
        --icon "${icon}" \
        --alignment "left" \
        --small \
        --messagefont "${message_font}" \
        --titlefont "${title_font}" \
        --button1text "OK" \
        --height "450"
}

dialog_still_running() {
    kill -0 "$dialog_pid" 2>/dev/null
}

cleanup_and_exit() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Cleaning up ..." >> ${log_file}
    rm -f /Users/Shared/dialogIndeterminate.txt
    invalidate_token
    exit 0
}
#######################################################################################################
# Bearer token functions
#######################################################################################################
# Variable declarations for bearer token
bearer_token=""
token_expiration_epoch="0"

get_bearer_token() {
    if [[ "${auth_method}" == "user_creds" ]]
    then
        response=$("${curl_path}" -s -u "${username}:${api_password}" "${jamf_pro_url}"/api/v1/auth/token -X POST)
        bearer_token=$(echo "${response}" | "${plutil_path}" -extract token raw - 2>/dev/null)
        # check token value was retrieved
        if [[ -z "${bearer_token}" ]]
        then
            echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to retrieve bearer token" >> "${log_file}"
            invalid_credentials_prompt
            credential_prompt
            get_bearer_token
            return
        fi
        token_expiration=$(echo "${response}" | "${plutil_path}" -extract expires raw - 2>/dev/null | awk -F . '{print $1}')
        token_expiration_epoch=$(date -j -f "%Y-%m-%dT%T" "${token_expiration}" +"%s")
        check_token_expiration_prompt
    fi
    if [[ "${auth_method}" == "client_secret" ]]
    then
        response=$("${curl_path}" --silent --location --request POST "${jamf_pro_url}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${username}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${api_password}")
        bearer_token=$(echo "${response}" | "${plutil_path}" -extract access_token raw -)
        token_expiration=$(echo "${response}" | "${plutil_path}" -extract expires_in raw -)
        now_epoch_utc=$(date -j -f "%Y-%m-%dT%T" "$(date -u +"%Y-%m-%dT%T")" +"%s")
        token_expiration_epoch=$((${now_epoch_utc} + ${token_expiration} - 1))
        check_token_expiration_prompt
    fi
    
    # Extract APBALANCEID from headers for sticky session handling
    ap_balance_id=$(echo "${response}" | grep -i 'Set-Cookie:' | grep -o 'APBALANCEID=[^;]*' | head -1)
}

check_token_expiration_prompt() {
    now_epoch_utc=$(date -j -f "%Y-%m-%dT%T" "$(date -u +"%Y-%m-%dT%T")" +"%s")

    if [[ -n "$token_expiration_epoch" && ($token_expiration_epoch -gt $now_epoch_utc) ]] 
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Token valid until the following epoch time: " "${token_expiration_epoch}" >> "${log_file}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to validate server details/credentials" >> "${log_file}"
        invalid_credentials_prompt
        credential_prompt
        get_bearer_token
    fi
}

check_token_expiration() {
    now_epoch_utc=$(date -j -f "%Y-%m-%dT%T" "$(date -u +"%Y-%m-%dT%T")" +"%s")
    if [[ $token_expiration_epoch -gt $now_epoch_utc ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Token valid until the following epoch time: " "${token_expiration_epoch}" >> "${log_file}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: No token available. Getting new token." >> "${log_file}"
        get_bearer_token
    fi
}

invalidate_token() {
    response_code=$("${curl_path}" -w "%{http_code}" -H "Authorization: Bearer ${bearer_token}" "${jamf_pro_url}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)
    if [[ ${response_code} == 204 ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Token successfully invalidated" >> "${log_file}"
        bearer_token=""
        token_expiration_epoch="0"
    elif [[ ${response_code} == 401 ]]
    then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Token already invalid" >> "${log_file}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: An unknown error occurred invalidating the token" >> "${log_file}"
    fi
}

#######################################################################################################
# Prompt for authentication method
auth_method_prompt

# Prompt for credentials
credential_prompt

# Prompt for credentials
get_bearer_token

# Prompt to choose new or existing group
group_option_prompt

# Get the members of the Smart Computer Group
echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Checking members of the group" >> "${log_file}"
member_list=$("${curl_path}" -X 'GET' -H "Authorization: Bearer ${bearer_token}" "${jamf_pro_url}/JSSResource/computergroups/name/${group_name2}" -H "accept: application/xml" -b "${ap_balance_id}" |  xmllint --format - |  grep -A3 "<computer>" | awk -F '[<>]' '/id/{print $3}')

# Count the members
member_count="0"
# Count the members using word count
member_count=$(echo "${member_list}" | wc -w | tr -d ' ')

# Prompt explaining no computers were found
if [[ -z ${member_list} ]]
then
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: There are 0 members in the group" >> "${log_file}"
    no_members_prompt
else

# Show number of devices in the Smart Computer Group and ask if we should remediate
echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: There are ${member_count} members in the group" >> "${log_file}"
echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Checking if remediation is desired" >> "${log_file}"
remediation_prompt

if  [[ $remediation_check == "Yes" ]]; then
    
    # Show Progress bar while the Jamf Management Framework is being redeployed on the computers
    redeployment_prompt
    
    for computer in ${member_list}; do
        
        if ! dialog_still_running; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: User Cancelled. Aborting remediation." >> "$log_file"
            cleanup_and_exit
        fi
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Redeploying Jamf Management Framework on Computer with ID: ${computer}" >> "$log_file"
        
        check_response -X 'POST' -H "Authorization: Bearer ${bearer_token}" "${jamf_pro_url}/api/v1/jamf-management-framework/redeploy/${computer}" -H 'accept: application/json' -d '' -b "${ap_balance_id}"
        
        echo "progresstext: Redeploying Jamf Management Framework on Computer with ID: ${computer}" >> "$command_file"
        
        check_token_expiration
        sleep 1
    done

fi
    # Close the progress dialog. Since indeterminate progress dialogs don't close automatically we are killing the dialog process
    pkill Dialog
    
    # Clean up
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Cleaning up ..." >> ${log_file}
    rm /Users/Shared/dialogIndeterminate.txt
    invalidate_token
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Done!" >> "${log_file}"
    done_prompt
fi
