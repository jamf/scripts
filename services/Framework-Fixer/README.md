![alt text](https://github.com/Sdelsaz/Framework-Fixer/blob/main/Images/Framework-Fixer-icon.png?raw=true)

# Framework Fixer

A script to help re-deploy the Jamf Pro Framework to a Smart Computer Group. An existing Smart Computer Group can be can used or a new one can be created.  The new Smart Computer Group will use the number of days since the last inventory update as criteria. A prompt will ask for the number of days to use for the criteria. 

This script leverages the Jamf Pro API and is to be run on an administrator's mac, it is not meant to be deployed using Jamf Pro.  The script must be run as root. Prompts are used to gather the server details and credentials for the API calls.  A Jamf Pro Username/password or an API Client/Secret can be used to generate the token.

Logs are written to /Users/Shared/Framework-Fixer.log

This script uses Bart Reardon's swiftDialog for user dialogs and requires this utility to be installed:

https://github.com/bartreardon/swiftDialog

![alt text](https://github.com/Sdelsaz/Framework-Fixer/blob/main/Images/1.png?raw=true)

![alt text](https://github.com/Sdelsaz/Framework-Fixer/blob/main/Images/2.png?raw=true)

![alt text](https://github.com/Sdelsaz/Framework-Fixer/blob/main/Images/3.png?raw=true)

![alt text](https://github.com/Sdelsaz/Framework-Fixer/blob/main/Images/5.png?raw=true)


## Note:

When reinstalling the Jamf management framework via this endpoint, Jamf Pro will clear or retain information for that computer based on the global re-enrollment settings you have configured. In addition, any policies scoped to the computer with a trigger of "enrollment complete" will be executed again. For more information, see Re-enrollment Settings in the [Jamf Pro Documentation](https://learn.jamf.com/en-US/bundle/jamf-pro-documentation-current/page/Re-enrollment_Settings.html).


## Requirements:

- swiftDialog: https://github.com/bartreardon/swiftDialog
- Jamf Pro 10.36 or later
- A valid MDM profile and network connection on the target computer
- A Jamf Pro User Account or API Role & Client with the following privileges:

Jamf Pro Server Objects:
Smart Computer Groups: Create, Read

Jamf Pro Server Settings:
Check-in: Read

Jamf Pro Server Actions:
Send Computer Remote Command to Install Package
