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

Author: Max Weber - intune-blog.com
Date: 2024/08/06
###>

# Set Error Action Preference to Stop
$ErrorActionPreference = 'Stop'

# How many cumulative updates should be treated as compliant? 
$numberOfUpdates = 3
Write-Verbose "Number of Updates treated as compliant: $numberOfUpdates"

# Allow all new builds by setting highestVersion to 10.0.*****.9999
$allowNewerBuilds = $true
Write-Verbose "Allow Newer Builds: $allowNewerBuilds"

# Set this to nonSecurity if you are deploying the monthly cumulative update preview updates [security / nonSecurity]
$updateClassification = 'security'
Write-Verbose "Update Classification: $updateClassification"

# Id of the compliance policy to update
$compliancePolicyId = 'bbd4352f-76cc-4417-b845-1da8bc8d68d1'
Write-Verbose "Compliance Policy Id: $compliancePolicyId"

# Define the Windows versions that should be handled
$validBuildNumbers = @('19044', '19045', '22621', '22631','26100')
Write-Verbose "Windows Version that will be handled: $validBuildNumbers"

# Enable update of Quality Update Policy to expedite update installation
$expediteQualityUpdate = $true
Write-Verbose "Expedite Quality Update Policy enabled: $expediteQualityUpdate"

# Id of the Quality Update policy
$qualityUpdatePolicyId = '97678ed0-c04d-4299-b861-170b1c63e3fc'
Write-Verbose "Quality Update Policy Id: $qualityUpdatePolicyId"

# Prefix for the display name of the quality update policy
$qualityUpdatePolicyDisplayNamePrefix = 'WIN - Updates - Expedite Windows Updates - D - '
Write-Verbose "Quality Update Policy Display Name prefix: $qualityUpdatePolicyDisplayNamePrefix"

# Days until reboot is enforced (0-2)
$qualityUpdatePolicyDaysUntilReboot = 1
Write-Verbose "Quality Update Policy days until reboot: $qualityUpdatePolicyDaysUntilReboot"

try {
    Write-Verbose "Establishing Connection to Graph API"

    # Connecto Managed Identity
    Connect-AzAccount -Identity | Out-Null
    Update-AzConfig -DisplaySecretsWarning $false | Out-Null

    # Get Credentials from Key Vault
    $VaultName = 'intune-blog-vault'
    $TenantId = Get-AzKeyVaultSecret -VaultName $VaultName -Name 'tenantid' -AsPlainText
    $ClientId = Get-AzKeyVaultSecret -VaultName $VaultName -Name 'clientid' -AsPlainText
    $ClientSecretCredential = Get-AzKeyVaultSecret -VaultName $VaultName -Name 'clientsecret' -AsPlainText
    $Creds = [System.Management.Automation.PSCredential]::new($ClientId, (ConvertTo-SecureString $ClientSecretCredential -AsPlainText -Force))

    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $creds -NoWelcome

    # For local testing
    #Connect-MgGraph -Scopes WindowsUpdates.ReadWrite.All,DeviceManagementConfiguration.ReadWrite.All

    Write-Verbose "Connection to Graph API established"
}
    catch {
        Write-Error "Failed to connect to MgGraph: $_"
        Exit 1
    }

####################################################################################################################
 

# Get Update Release Information
try {
    #Create filter statement
    Write-Verbose "Creating filter Statement for Windows Update query"
    $filter = '$filter=microsoft.graph.windowsUpdates.qualityUpdateCatalogEntry/qualityUpdateClassification eq ''' + $updateClassification  + '''&' 
    $uri = 'https://graph.microsoft.com/beta/admin/windows/updates/catalog/entries?$select=microsoft.graph.windowsUpdates.qualityUpdateCatalogEntry/productRevisions&$expand=microsoft.graph.windowsUpdates.qualityUpdateCatalogEntry/productRevisions&' + $filter + '$orderby=releaseDateTime%20desc&$top=' + $numberOfUpdates
    Write-Verbose "Request URI: $uri"
    $productRevisions = $(Invoke-MgGraphRequest -Method GET -Uri $uri).value.productRevisions
    Write-Verbose "Successfully received update data"
}
catch {
    Write-Error "Failed to get update data. Do you have the required license? Error: $_"
    Exit 1
}

# Get required data for each Windows version
$validOperatingSystemBuildRanges = @()
$expediteQualityUpdateReleaseTime = ""

Write-Verbose "Constructing valid builds object for compliance policy"
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
        
        Write-Verbose "$($highestVersion.product) - $($highestVersion.version): $($buildRangeObject.lowestVersion) - $($buildRangeObject.highestVersion)"
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
Write-Verbose "Updating Compliance Policy"

$compliancePolicyBody = @{
    "@odata.type" = "#microsoft.graph.windows10CompliancePolicy";
    "validOperatingSystemBuildRanges" = $validOperatingSystemBuildRanges
}

try {    
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$compliancePolicyId" -Body $compliancePolicyBody
    Write-Verbose "Successfully updated Compliance Policy"
}
catch {
    Write-Error "Failed to update compliance policy: $_"
}


# Patch Quality Update Policy
if ($expediteQualityUpdate) {
    Write-Verbose "Updating Expedite Quality Update Policy"   
    
    $expediteQualityUpdateBody = @{
        "displayName" = $qualityUpdatePolicyDisplayNamePrefix + $(Get-Date $([DateTime]$expediteQualityUpdateReleaseTime) -Format "yyyy.MM")
        "expeditedUpdateSettings" = @{
            "daysUntilForcedReboot" = $qualityUpdatePolicyDaysUntilReboot;
            "qualityUpdateRelease" = $expediteQualityUpdateReleaseTime;
        }
    }
    Write-Verbose "Display Name: $($expediteQualityUpdateBody.displayName)"
    Write-Verbose "Quality Update Release: $($expediteQualityUpdateBody.expeditedUpdateSettings.qualityUpdateRelease)"

    try {
        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles/$qualityUpdatePolicyId" -Body $expediteQualityUpdateBody        
        Write-Verbose "Successfully updated Expedite Quality Update Policy"
    }
    catch {
        Write-Error "Failed to update Expedite Quality Update policy: $_"
    }
}

Write-Verbose "Script execution finished"