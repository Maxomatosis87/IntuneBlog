<#
Author: Max Weber / http://blog.maxweber.org

Version 1.0 - 2024/01/08

This script is used to implement a similar functionality like Custom Compliance Scripts for Windows devices.
This script collects all macOS devices from Intune that have a specific result from custom attribute script execution.
For these devices ExtensionAttribute1 is set to "Compliant". Devices that already have the ExtAttr. but aren't compliant anymore, the ExtAttr. will be cleared.
The ExtensionAttribute1 can be used as a device filter on a Conditional Access policy.

#>

# ID of the Custom Attribute Script in Intune
$scriptId = "5066b9f8-da82-48b5-a925-8628207d8656"

# Required Output of the script for a device to be 'compliant'
$desiredResult = "Running"

# Output which should be written to the ExtensionAttribute1 if a device is compliant
$desiredExtensionAttributeOutput = "Compliant"


# Connecto Managed Identity
Connect-AzAccount -Identity

# Credentials from Key Vault
$VaultName = "intune-keyvault"
$TenantId = Get-AzKeyVaultSecret -VaultName $VaultName -Name 'TenantId' -AsPlainText
$ClientId = Get-AzKeyVaultSecret -VaultName $VaultName -Name 'AppRegistration-IntuneAutomation-ClientId' -AsPlainText
$ClientSecretCredential = Get-AzKeyVaultSecret -VaultName $VaultName -Name 'AppRegistration-IntuneAutomation-ClientSecret' -AsPlainText
$Creds = [System.Management.Automation.PSCredential]::new($ClientId, (ConvertTo-SecureString $ClientSecretCredential -AsPlainText -Force))

Connect-MgGraph -NoWelcome -ClientSecretCredential $Creds -TenantId $TenantId

# Get Devices where desired Result matches
$compliantDevicesEntraId = @()
try {
    Write-Output "Getting devices with Result '$desiredResult' from script $scriptId"
    $compliantDevices = $(Get-MgBetaDeviceManagementScriptDeviceRunState -ErrorAction Stop -All -DeviceManagementScriptId $scriptId -Filter "ResultMessage eq '$desiredResult'" -ExpandProperty ManagedDevice).ManagedDevice.Id
    Write-Output "Found $($compliantDevices.Count) Compliant Devices in Intune"
    $compliantDevices | ForEach-Object {        
        $entraDeviceId = $(Get-MgBetaDeviceManagementManagedDevice -ManagedDeviceId $_).AzureAdDeviceId
        if($entraDeviceId -ne "00000000-0000-0000-0000-000000000000") {
            $compliantDevicesEntraId += $entraDeviceId
        }
    }
    Write-Output "Found $($compliantDevicesEntraId.Count) Compliant Devices with valid EntraID device object"
}
catch {
    Write-Error $_
    Write-Error "Aborting Script"
    Exit 1
}

# Remove ExtensionAttribute1 from all devices which are not compliant
$currentMembers = Get-MgBetaDevice -Filter "OperatingSystem eq 'macMDM'" -all -Property DeviceId, ExtensionAttributes | Select-Object -Property DeviceId, ExtensionAttributes -ExpandProperty ExtensionAttributes | Where-Object {$_.ExtensionAttribute1 -eq $desiredExtensionAttributeOutput}
$currentMembers | Where-Object {
    $_.DeviceId -ne $null -and !$compliantDevicesEntraId.Contains($($_.DeviceId))} | ForEach-Object {
        try {
            Write-Output "Removing ExtensionAttribute1 from $($_.DeviceId)"
            $params = @{
                extensionAttributes = @{
                    extensionAttribute1 = ""
                }
            }        
            Update-MgBetaDeviceByDeviceId -DeviceId $_.DeviceId -BodyParameter $params
        }
        catch {
            Write-Error $_
        }
}

# Write ExtensionAttribute1 on new devices
$compliantDevicesEntraId | Where-Object {
    !$currentMembers -or !$currentMembers.DeviceId.Contains($_)} | ForEach-Object {        
        try {
            Write-Output "Writing ExtensionAttribute1 for device $_"
            $params = @{
                extensionAttributes = @{
                    extensionAttribute1 = $desiredExtensionAttributeOutput
                }
            }        
            Update-MgBetaDeviceByDeviceId -DeviceId $_ -BodyParameter $params       
        }
        catch {
            Write-Error $_
        }
}