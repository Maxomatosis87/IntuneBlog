<###
Synopsis

This PowerShell script automates the management of Windows update compliance and quality update policies within an organization's environment using the Microsoft Graph API. The script is designed to help administrators ensure that devices are compliant with specific update policies, particularly focusing on the most recent cumulative updates.

Key Functions:
Configuration Settings:

The script defines how many cumulative updates (e.g., security or non-security) should be considered compliant, which versions of Windows should be handled, and whether newer builds are allowed.
It also configures whether to expedite quality updates and sets the parameters for enforcing reboots after updates.
Connecting to Azure and Microsoft Graph:

The script uses a managed identity to connect to Azure and retrieve credentials from an Azure Key Vault.
It then connects to the Microsoft Graph API using these credentials.
Retrieving Update Information:

The script fetches information about the most recent cumulative updates from the Microsoft Graph API, filtered by the specified update classification (security or non-security).
It identifies the relevant Windows versions and their respective update details.
Building Compliance Policies:

The script creates a list of valid operating system build ranges based on the updates retrieved.
This list is used to update an existing Windows compliance policy, ensuring that devices running specified builds are treated as compliant.
Updating Quality Update Policies:

If the option to expedite updates is enabled, the script updates the quality update policy with the release date of the latest update and configures the enforced reboot timeline.
Error Handling:

The script includes error handling to manage exceptions during API calls, ensuring that issues are logged and the script exits gracefully if critical errors occur.
Intended Use:
This script is intended for IT administrators managing large Windows environments who need to enforce compliance with specific update policies and ensure that critical updates are installed in a timely manner.

Author: Max Weber - intuneblog.org
Date: 2024/08/06
###>

# How many cumulative updates should be treated as compliant? 
$numberOfUpdates = 3

# Allow all new builds by setting highestVersion to 10.0.*****.9999
$allowNewerBuilds = $true

# Set this to nonSecurity if you are deploying the monthly cumulative update preview updates [security / nonSecurity]
$updateClassification = 'security'

# Id of the compliance policy to update
$compliancePolicyId = '6a6207c6-720a-49f2-96fe-fb519127dad0'

# Define the Windows versions that should be handled
$validBuildNumbers = @('19044', '19045', '22621', '22631','26100')

# Enable update of Quality Update Policy to expedite update installation
$expediteQualityUpdate = $true
# Id of the Quality Update policy
$qualityUpdatePolicyId = '45743b48-c406-4c1c-a71e-f5b5a0585782'
# Prefix for the display name of the quality update policy
$qualityUpdatePolicyDisplayNamePrefix = 'WIN - Updates - Expedite Windows Updates - D - '
# Days until reboot is enforced (0-2)
$qualityUpdatePolicyDaysUntilReboot = 1

<#
# Connecto Managed Identity
Connect-AzAccount -Identity

# Get Credentials from Key Vault
$TenantId = Get-AzKeyVaultSecret -VaultName '<YOUR VAULT NAME HERE>' -Name 'tenant' -AsPlainText
$ClientId = Get-AzKeyVaultSecret -VaultName '<YOUR VAULT NAME HERE>' -Name 'clientid' -AsPlainText
$ClientSecretCredential = Get-AzKeyVaultSecret -VaultName '<YOUR VAULT NAME HERE>' -Name 'clientsecret' -AsPlainText
$Creds = [System.Management.Automation.PSCredential]::new($ClientId, (ConvertTo-SecureString $ClientSecretCredential -AsPlainText -Force))

Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $creds -NoWelcome
#>
# For local testing
Connect-MgGraph -Scopes WindowsUpdates.ReadWrite.All,DeviceManagementConfiguration.ReadWrite.All

####################################################################################################################
 

# Get Update Release Information
try {
    #Create filter statement
    $filter = '$filter=microsoft.graph.windowsUpdates.qualityUpdateCatalogEntry/qualityUpdateClassification eq ''' + $updateClassification  + '''&' 
    $uri = 'https://graph.microsoft.com/beta/admin/windows/updates/catalog/entries?$select=microsoft.graph.windowsUpdates.qualityUpdateCatalogEntry/productRevisions&$expand=microsoft.graph.windowsUpdates.qualityUpdateCatalogEntry/productRevisions&' + $filter + '$orderby=releaseDateTime%20desc&$top=' + $numberOfUpdates
    $productRevisions = $(Invoke-MgGraphRequest -Method GET -Uri $uri).value.productRevisions
}
catch {
    Write-Error $_
    Exit 1
}

# Get required data for each Windows version
$validOperatingSystemBuildRanges = @()
$expediteQualityUpdateReleaseTime = ""

$validBuildNumbers | ForEach-Object {
    [array]$versions = $productRevisions | Where-Object id -match "10.0.$_" | Sort-Object -Property releaseDateTime
    if($versions) {
        $highestVersion = $versions[-1]
        $lowestVersion = $versions[0]        
        $buildRangeObject = @{
            "@odata.type" = "microsoft.graph.operatingSystemVersionRange";
            "description" = "$($highestVersion.product) - $($highestVersion.version)";
            "lowestVersion" = $lowestVersion.Id.toString();
            "highestVersion" = $allowNewerBuilds ? "10.0.$_.9999" : $highestVersion.Id.toString();
        }
        $validOperatingSystemBuildRanges += $buildRangeObject
        
        if(-not $expediteQualityUpdateReleaseTime) {
            $expediteQualityUpdateReleaseTime = $lowestVersion.releaseDateTime
        }
        
        Write-Host "$($highestVersion.product) - $($highestVersion.version): $($buildRangeObject.lowestVersion) - $($buildRangeObject.highestVersion)"
        Clear-Variable lowestVersion, highestVersion, buildRangeObject, versions
    }
    else {
        Write-Error "No Updates found for $_"
    }
}

if (-not $validOperatingSystemBuildRanges -or (-not $validOperatingSystemBuildRanges.Count -gt 0)) {
    Write-Error "No valid updates found! Exiting script"
    Exit 1
}

# Patch Compliance Policy
$body = @{
    "@odata.type" = "#microsoft.graph.windows10CompliancePolicy";
    "validOperatingSystemBuildRanges" = $validOperatingSystemBuildRanges
}
try {
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$compliancePolicyId" -Body $body
}
catch {
    Write-Error $_
}


# Patch Quality Update Policy 
if ($expediteQualityUpdate) {    
    $body = @{
        "displayName" = $qualityUpdatePolicyDisplayNamePrefix + $expediteQualityUpdateReleaseTime
        "expeditedUpdateSettings" = @{
            "daysUntilForcedReboot" = $qualityUpdatePolicyDaysUntilReboot;
            "qualityUpdateRelease" = $expediteQualityUpdateReleaseTime;
        }
    }
    try {
        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles/$qualityUpdatePolicyId" -Body $body        
    }
    catch {
        Write-Error $_
    }
}