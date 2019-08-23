#configure new SDDC script
# Chris Lennon
# Updated: 07/22/2019
#
# Params
#
Param (
    [Parameter(Mandatory = $true)][String]$WSDDCName
)

# Bind command line parameters to variables
#
# Number of webserver VMs to create
$vmcount = "2"
#
# Template VMs will be deployed from
$template = "photoapp-u"
#
# vCenter customization specification to apply
$customspecification = "LinuxSpec"
#
# Prefix for all VMs to be created
$VMprefix = "webserver"
#
# Datastore where VMs will be created
#(Should not need changed for VMware Cloud on AWS)
$ds = "WorkloadDatastore"
#
# vCenter folder where VMs will be deployed
# (Folder will be created if it does not exist under the Workloads folder)
$Folder = "Workloads"
$createFolders = @("Production", "Test", "Automation", "DR", "Database", "Horizon")
#
# vSphere cluster name
# (Should not need changed for VMware Cloud on AWS)
$Cluster = "Cluster-1"
#
# Root Resource pool name
# (Should not need changed for VMware Cloud on AWS)
$ResourcePool = "Compute-ResourcePool"
$createPools = @("Test-ResourcePool", "Prod-ResourcePool", "DR-ResourcePool", "Horizon-ResourcePool")
#
# Do NOT modify anything below this line
#_______________________________________________________
#
# Gather data from workshop json
$data = get-content "..\..\json\workshop.json" | ConvertFrom-Json
$data += get-content "..\..\json\elw.json" | ConvertFrom-Json
$data += get-content "..\..\json\set.json" | ConvertFrom-Json
foreach ($i in $data) {
    if ($i.SDDCName -eq $WSDDCName) {
        write-host "Gathering info from" $i.OrgName $i.SDDCName
        $RefreshToken = $i.RefreshToken
        $orgName = $i.Orgname
        $sddcName = $i.SDDCName
        $networkSegmentName = $i.SDDCName + "-cgw-network-1"
        $networkSegmentGateway = $i.NetworkGateway
        $networkSegmentDHCP = $i.DHCPRange
    }
}

Set-PowerCLIConfiguration -Scope User -ParticipateInCeip $true -confirm:$false

#Import NSXT commands
Import-Module .\VMware.VMC.NSXT.psd1

#Connect-VMC to get vCenter creds
Connect-VmcServer -RefreshToken $RefreshToken

#Connect to NSX-t Proxy
$nsxConnect = Connect-NSXTProxy -RefreshToken $RefreshToken -OrgName $orgName -SDDCName $sddcName #-Verbose

#create 443 firewall rule to access vCenter
$results = Get-NSXTFirewall -Name "vCenter 443 (Automated)" -GatewayType "MGW"
if ($results.name -eq $null) {
    $nsxtResults = New-NSXTFirewall -name "vCenter 443 (Automated)" -GatewayType "MGW" -SequenceNumber 2 -SourceGroup "ANY" -DestinationGroup "vCenter" -Service "HTTPS" -Action "ALLOW"# -Scope "All"#-Troubleshoot $true
}
else {
    Write-Host -ForegroundColor Yellow "Skipping mgw firewall already exists"
}

#create network segment
$results = Get-NSXTSegment -Name $networkSegmentName
if ($results.name -eq $null) {
    $nsxtResults = New-NSXTSegment -Name $networkSegmentName -Gateway $networkSegmentGateway -DHCP -DHCPRange $networkSegmentDHCP
}
else {
    Write-Host -ForegroundColor Yellow "Skipping network segment" $networkSegmentName "already exists"
}

#get new public IP
$results = Get-NSXTPublicIP -Name $template
if ($results.display_name -eq $null) {
    $nsxtResults = $publicIp = New-NSXTPublicIP -Name $template
}
else {
    Write-Host -ForegroundColor Yellow "Skipping IP already exists" $results.ip 
}

#create NAT
$results = Get-NSXTNatRule -Name $template
if ($results.display_name -eq $null) {
    $nsxtResults = New-NSXTNatRule -Name $template -PublicIP $publicIp.ip -InternalIp "10.10.11.100" -Service "HTTP"
}
else {
    Write-Host -ForegroundColor Yellow "Skipping NAT already exists"
}

#create NSXT Group for webserver
$results = Get-NSXTGroup -Name $template -GatewayType "CGW"
if ($results.name -eq $null) {
    $nsxtResults = New-NSXTGroup -Name $template -GatewayType "CGW" -IPAddress $publicIp.ip
}
else {
    Write-Host -ForegroundColor Yellow "Skipping NSXT group already exists"
}

#create mysql firewall rule in cgw to VPC
$results = Get-NSXTFirewall -Name "AWS Outbound" -GatewayType "CGW"
if ($results.name -eq $null) {
    $nsxtResults = New-NSXTFirewall -name "AWS Outbound" -GatewayType "CGW" -SequenceNumber 2 -SourceGroup "ANY" -DestinationInfraGroup "Connected VPC Prefixes" -Service "MySQL" -Action "ALLOW" -InfraScope "VPC Interface" #-Troubleshoot $true
}
else {
    Write-Host -ForegroundColor Yellow "Skipping cgw firewall already exists"
}

#create 80 firewall rule in cgw
$results = Get-NSXTFirewall -Name "HTTP Inbound" -GatewayType "CGW"
if ($results.name -eq $null) {
    $nsxtResults = New-NSXTFirewall -name "HTTP Inbound" -GatewayType "CGW" -SequenceNumber 1 -SourceGroup "ANY" -DestinationGroup $template -Service "HTTP" -Action "ALLOW" -InfraScope "All Uplinks" #-Troubleshoot $true
}
else {
    Write-Host -ForegroundColor Yellow "Skipping cgw firewall already exists"
}

#done with the NSXT module
remove-module VMware.VMC.NSXT

pause
#get creds
$sddcCreds = Get-VMCSDDCDefaultCredential -Org $orgName -sddc $sddcName
$vCenter = $sddcCreds.vc_public_ip
$vCenterUser = $sddcCreds.cloud_username
$vCenterUserPassword = $sddcCreds.cloud_password

#ignore cert
set-PowerCLIConfiguration -InvalidCertificateAction Ignore -confirm:$false
write-host "Establishing connection to $vCenter" -foreground green
$results = Connect-viserver $vCenter -user $vCenterUser -password $vCenterUserPassword -WarningAction 0

#Create content library and connect to S3
$results = Get-ContentLibraryItem -Name $template -EA SilentlyContinue
if ($results.ContentLibrary -eq $null) {
    #connect to cis server
    $results = Connect-cisserver $vCenter -user $vCenterUser -password $vCenterUserPassword -WarningAction 0
    $datastoreID = (Get-Datastore -Name $ds).extensiondata.moref.value

    # Create a Subscribed content library on an existing datastore
    $ContentCatalog = Get-CisService com.vmware.content.subscribed_library
    $createSpec = $ContentCatalog.help.create.create_spec.Create()
    $createSpec.subscription_info.authentication_method = "NONE"
    $createSpec.subscription_info.ssl_thumbprint = "05:1B:5C:67:25:E1:3E:5F:B9:95:66:57:C1:3B:99:DA"
    $createSpec.subscription_info.automatic_sync_enabled = $true
    $createSpec.subscription_info.subscription_url = "http://vmc-elw-vms.s3-accelerate.amazonaws.com/lib.json"
    $createSpec.subscription_info.on_demand = $false
    $createSpec.subscription_info.password = $null
    $createSpec.server_guid = $null
    $createspec.name = "vmc-content-library"
    $createSpec.description = "workshop templates"
    $createSpec.type = "SUBSCRIBED"
    $createSpec.publish_info = $null
    $datastoreID = [VMware.VimAutomation.Cis.Core.Types.V1.ID]$datastoreID
    $StorageSpec = New-Object PSObject -Property @{
        datastore_id = $datastoreID
        type         = "DATASTORE"
    }
    $CreateSpec.storage_backings.Add($StorageSpec)
    $UniqueID = [guid]::NewGuid().tostring()
    $ContentCatalog.create($UniqueID, $createspec)
    #Disconnect-CIServer *
}
else {
    Write-Host -ForegroundColor Yellow "Skipping content library already exists"
}

$ComputePool = Get-ResourcePool -Location $Cluster -server $server -Name $ResourcePool
#create resource pools
for ($i = 0; $i -lt $createPools.length; $i++) {
    $results = Get-ResourcePool -name $createPools[$i] -EA SilentlyContinue
    if ($results.name -eq $null) {
        $poolResults = New-ResourcePool -Location $computePool -Name $createPools[$i] 
        Write-Host -Foreground Green "Created resource pool" $poolResults.Name
    }
    else {
        Write-Host -ForegroundColor Yellow "Skipping resource pool" $createPools[$i] "already exists"
    }
}

#create folders
for ($i = 0; $i -lt $createFolders.length; $i++) {
    $results = Get-View -viewtype folder -filter @{"name" = $createFolders[$i] } -EA SilentlyContinue
    if ($results.Name -eq $null) {
        $results = (Get-View -viewtype folder -filter @{"name" = "Workloads" }).CreateFolder($createFolders[$i])
        Write-Host -Foreground Green "Created folder" $createFolders[$i]
    }
    else {
        Write-Host -ForegroundColor Yellow "Skipping folder" $createFolders[$i] "already exists"
    }
}

#Create Windows customization spec
$results = Get-OSCustomizationSpec -Name "Windows" -EA SilentlyContinue
if ($results.name -eq $null) {
    $results = new-OSCustomizationSpec -Name "Windows" -FullName "administrator" -ChangeSID -OrgName "VMC" -Workgroup "VMC" -AdminPassword "VMware1!" -OSType Windows
    Write-Host -Foreground Green "Created Windows Customization Spec"
}
else {
    Write-Host -ForegroundColor Yellow "Skipping Custom spec" $results.name "already exists"
}

#create Linux customization spec
$results = Get-OSCustomizationSpec -Name $customspecification -EA SilentlyContinue
if ($results.name -eq $null) {
    $results = new-OSCustomizationSpec -Name $customspecification -Description "Standard Linux Customization Specification" -Domain "corp.local" -DnsServer "8.8.8.8", "8.8.4.4" -DnsSuffix "corp.local" -OSType Linux
    Write-Host -Foreground Green "Created Linux Customization Spec"
}
else {
    Write-Host -ForegroundColor Yellow "Skipping Custom spec" $results.name "already exists"
}

#See if template is ready to be deployed from in content library
#$results = Get-ContentLibraryItem -Name "centos-web" -EA SilentlyContinue
while ((Get-ContentLibraryItem -Name $template).SizeGB -le 1.9) {
    $results = (Get-ContentLibraryItem -Name $template).SizeGB
    Write-Host -ForegroundColor Yellow "Template size" $results". Waiting 30 seconds."
    Start-Sleep -Seconds 30 
}  

#create vm's
$dFolder = "Production"
$dResource = "Prod-ResourcePool"
$folderexist = get-folder -Type VM | Where-Object { $_.name -eq $Folder }
if ($folderexist -eq $null) {
    Write-Host "$foldername folder doesn't exist" -BackgroundColor Red
    New-Folder -Name $Folder -Location (Get-Folder -Name "Workloads" )
}

1..$vmcount | foreach {
    $y = "{0:D2}" -f $_
    $VMname = $VMprefix + $y
    $ESXi = Get-Cluster $Cluster | Get-VMHost -state connected | Get-Random
    write-host "Cloning of VM $VMname started on host $ESXi" -foreground green
    $ContentLibraryVM = Get-ContentLibraryItem -Name $template #| Where-Object {$_.ContentLibrary -eq "set-content-library"}
    $result = New-VM -Name $VMname -ContentLibraryItem $ContentLibraryVM -VMHost $ESXi -Datastore $ds -Location $dFolder -ResourcePool $dResource
    $result = Set-VM -VM $VMname -OSCustomizationSpec $customspecification -Confirm:$false
    $result = get-vm $VMname | Get-NetworkAdapter | Set-NetworkAdapter -NetworkName $networkSegmentName -Confirm:$false
    write-host "Power On of the VM $VMname initiated"  -foreground green
    $result = Start-VM -VM $VMname -confirm:$false -RunAsync
}

#done disconnect from vCenter
disconnect-viserver -server * -Confirm:$false -WarningAction SilentlyContinue
