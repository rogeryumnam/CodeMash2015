param ( 
    # Cloud service name to deploy the VMs to 
    [Parameter(Mandatory = $true)] 
    [String]$ServiceName, 
     
    # Name of the Virtual Machine to create 
    [Parameter(Mandatory = $true)] 
    [String]$VMName, 
     
    # Location, this is not a mandatory parameter. THe script checkes the existence if service is not found. 
    [Parameter(Mandatory = $true)] 
    [String]$Location, 
     
    # Disk size in GB 
    [Parameter(Mandatory = $true)] 
    [Int32]$DiskSizeInGB, 
     
    # Number of data disks to add to each virtual machine 
    [Parameter(Mandatory = $true)] 
    [Int32]$NumberOfDisks) 
 
# The script has been tested on Powershell 3.0 
Set-StrictMode -Version 3 
 
# Following modifies the Write-Verbose behavior to turn the messages on globally for this session 
$VerbosePreference = "Continue" 

$ErrorActionPreference = "Stop"


<# 
.SYNOPSIS 
  Returns the latest image for a given image family name filter. 
.DESCRIPTION 
  Will return the latest image based on a filter match on the ImageFamilyName and 
  PublisedDate of the image.  The more specific the filter, the more control you have 
  over the object returned. 
.EXAMPLE 
  The following example will return the latest SQL Server image.  It could be SQL Server 
  2014, 2012 or 2008 
     
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server*" 
 
  The following example will return the latest SQL Server 2014 image. This function will 
  also only select the image from images published by Microsoft.   
    
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server 2014*" -OnlyMicrosoftImages 
 
  The following example will return $null because Microsoft doesn't publish Ubuntu images. 
    
    Get-LatestImage -ImageFamilyNameFilter "*Ubuntu*" -OnlyMicrosoftImages 
#> 
function Get-LatestImage 
{ 
    param 
    ( 
        # A filter for selecting the image family. 
        # For example, "Windows Server 2012*", "*2012 Datacenter*", "*SQL*, "Sharepoint*" 
        [Parameter(Mandatory = $true)] 
        [String] 
        $ImageFamilyNameFilter, 
 
        # A switch to indicate whether or not to select the latest image where the publisher is Microsoft. 
        # If this switch is not specified, then images from all possible publishers are considered. 
        [Parameter(Mandatory = $false)] 
        [switch] 
        $OnlyMicrosoftImages 
    ) 
 
    # Get a list of all available images. 
    $imageList = Get-AzureVMImage 
 
    if ($OnlyMicrosoftImages.IsPresent) 
    { 
        $imageList = $imageList | 
                         Where-Object { ` 
                             ($_.PublisherName -ilike "Microsoft*" -and ` 
                              $_.ImageFamily -ilike $ImageFamilyNameFilter ) } 
    } 
    else 
    { 
        $imageList = $imageList | 
                         Where-Object { ` 
                             ($_.ImageFamily -ilike $ImageFamilyNameFilter ) }  
    } 
 
    $imageList = $imageList |  
                     Sort-Object -Unique -Descending -Property ImageFamily | 
                     Sort-Object -Descending -Property PublishedDate 
 
    $imageList | Select-Object -First(1) 
} 

# Add-AzureAccount
Set-AzureSubscription -SubscriptionName "Azure MVP MSDN Subscription" -CurrentStorageAccountName "1devday" 
Select-AzureSubscription -SubscriptionName "Azure MVP MSDN Subscription" -Default

# Check if the current subscription's storage account's location is the same as the Location parameter 
$subscription = Get-AzureSubscription -Current 
$currentStorageAccountLocation = (Get-AzureStorageAccount -StorageAccountName $subscription.CurrentStorageAccountName).GeoPrimaryLocation 
 
if ($Location -ne $currentStorageAccountLocation) 
{ 
    throw "Selected location parameter value, ""$Location"" is not the same as the active (current) subscription's current storage account location ` 
        ($currentStorageAccountLocation). Either change the location parameter value, or select a different storage account for the ` 
        subscription." 
} 
 
# Get an image to provision virtual machines from. 
$imageFamilyNameFilter = "Windows Server 2012 Datacenter" 
$image = Get-LatestImage -ImageFamilyNameFilter $imageFamilyNameFilter -OnlyMicrosoftImages 
if ($image -eq $null) 
{ 
    throw "Unable to find an image for $imageFamilyNameFilter to provision Virtual Machine." 
} 
 
# Check if hosted service with $ServiceName exists 
$existingService = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue 
 
# Does the VM exist? If the VM is already there, just add the new disk 
$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $VMName -ErrorAction SilentlyContinue 
 
if ($existingService -eq $null) 
{ 
    if ($Location -eq "") 
    { 
        throw "Service does not exist, please specify the Location parameter" 
    }  
    New-AzureService -ServiceName $ServiceName -Location $Location 
} 
 
if (($Location -ne "") -and ($existingService -ne $null)) 
{ 
    if ($existingService.Location -ne $Location) 
    { 
        Write-Warning "There is a service with the same name on a different location. Location parameter will be ignored." 
    } 
} 
 
Write-Verbose "Prompt user for administrator credentials to use when provisioning the virtual machine(s)." 
$credential = Get-Credential 
Write-Verbose "Administrator credentials captured.  Use these credentials to login to the virtual machine(s) when the script is complete." 
 
# Configure the new Virtual Machine. 
$userName = $credential.GetNetworkCredential().UserName 
$password = $credential.GetNetworkCredential().Password 
 
if ($existingVm -ne $null) 
{ 
    # Find the starting LUN for the new disks 
    $startingLun = ($existingVm | Get-AzureDataDisk | Measure-Object Lun -Maximum).Maximum + 1 
     
    for ($index = $startingLun; $index -lt $NumberOfDisks + $startingLun; $index++) 
    {  
        $diskLabel = "disk_" + $index 
        $existingVm = $existingVm |  
                           Add-AzureDataDisk -CreateNew -DiskSizeInGB $DiskSizeInGB ` 
                               -DiskLabel $diskLabel -LUN $index         
    } 
     
    $existingVm | Update-AzureVM 
} 
else 
{ 
    $vmConfig = New-AzureVMConfig -Name $VMName -InstanceSize Small -ImageName $image.ImageName |  
    			Add-AzureProvisioningConfig -Windows -AdminUsername $userName -Password $password  
				
	# Custom script extension
	$vmConfig = Set-AzureVMCustomScriptExtension -VM $vmConfig -ContainerName "vmstartup" -FileName "formatdisk.ps1" -Run "formatdisk.ps1"
	
     
    for ($index = 0; $index -lt $NumberOfDisks; $index++) 
    {  
        $diskLabel = "disk_" + $index 
        $vmConfig = $vmConfig |  
                        Add-AzureDataDisk -CreateNew -DiskSizeInGB $DiskSizeInGB -DiskLabel $diskLabel -LUN $index         
    } 
     
    # Create the Virtual Machine and wait for it to boot. 
    New-AzureVM -ServiceName $ServiceName -VMs $vmConfig -WaitForBoot
	
	$status = Get-AzureVM -ServiceName $ServiceName -Name $VMName
}