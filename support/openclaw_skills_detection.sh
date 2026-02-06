#!/bin/bash

####################################################################################################
#
# Copyright (c) 2022, Jamf Software, LLC.  All rights reserved.
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
####################################################################################################


# Function to find openclaw directory
find_openclaw_dir() {
    # Get the current console user
    CURRENT_USER=$(stat -f "%Su" /dev/console 2>/dev/null || who | awk '/console/ {print $1}' | head -n 1)
    
    # If we can't determine user, try logname or $USER
    if [ -z "$CURRENT_USER" ]; then
        CURRENT_USER=$(logname 2>/dev/null || echo "$USER")
    fi
    
    # Get user's home directory
    if [ -n "$CURRENT_USER" ]; then
        USER_HOME=$(eval echo "~$CURRENT_USER")
    else
        USER_HOME="$HOME"
    fi
    
    # Define openclaw config path
    OPENCLAW_DIR="${USER_HOME}/.openclaw"
    
    echo "$OPENCLAW_DIR"
}

# Main execution
OPENCLAW_DIR=$(find_openclaw_dir)
OPENCLAW_JSON="${OPENCLAW_DIR}/openclaw.json"

# Check if openclaw is installed
if [ ! -d "$OPENCLAW_DIR" ]; then
    echo "<result>Not Installed</result>"
    exit 0
fi

# Check if config file exists
if [ ! -f "$OPENCLAW_JSON" ]; then
    echo "<result>Config File Not Found</result>"
    exit 0
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "<result>jq Not Available</result>"
    exit 0
fi

# Extract enabled skills
ENABLED_SKILLS=$(cat "$OPENCLAW_JSON" | jq -r '.skills.entries | to_entries | .[] | select(.value.enabled).key' 2>/dev/null)

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "<result>Error Parsing JSON</result>"
    exit 0
fi

# Check if any skills were found
if [ -z "$ENABLED_SKILLS" ]; then
    echo "<result>No Enabled Skills</result>"
    exit 0
fi

# Format output: Convert newline-separated skills to comma-separated
SKILLS_LIST=$(echo "$ENABLED_SKILLS" | tr '\n' ',' | sed 's/,$//')

echo "<result>$SKILLS_LIST</result>"
exit 0
