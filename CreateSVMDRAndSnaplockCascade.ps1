Param(
	[Parameter(Mandatory=$true)][string]$Cluster
    )
<#usage
#Lab 9.10.1 : https://labondemand.netapp.com/lab/eapontap9101

Architectl
#enable AntiRansomware on vol1 and vol2
	Cluster1::> vol modify -vserver prod -volume vol* -anti-ransomware-state dry-run

#Modify create_dataset.sh
	sed -i 's/sleep/#sleep/g' ~/create_dataset.sh

#Mount vol1 and vol2
	mkdir /mnt2	
	mount -t nfs prod:/vol1 /mnt
	mount -t nfs prod:/vol2 /mnt2

#create a source file in /mnt and /mnt2
	1mb file can be downloaded here : https://web-utility.com/en/sample/document/sample-txt-file-download
	vi /mnt/src_file
	cp /mnt/src_file /mnt2/

#Run create_dataset script from /mnt
	cd /mnt
	sh ~/create_dataset.sh

#Let script run until extension will be discovered (Approx 25 min)
	Cluster1::> security anti-ransomware volume workload-behavior show -vserver prod -volume vol1

#switch autonomous ARW to enabled (Create a Clone to be able to demonstrate several times)
	Cluster1::> snapshot create -vserver prod -volume vol1 -snapshot BeforeAttack
	Cluster1::> vol clone create -vserver prod -flexclone vol3 -vserver-dr-protection unprotected -junction-path /vol3 -space-guarantee none -parent-snapshot BeforeAttack -type RW -parent-volume vol1 -parent-vserver prod
	Cluster1::> set d -c off;vol clone split start -vserver prod -flexclone vol3
	Cluster1::> vol modify -vserver prod -volume vol1 -anti-ransomware-state enable

#Modify simulate_attack.sh
	sed -i 's/sleep/#sleep/g' ~/simulate_attack.sh

#Launch first Attack (Approx 20 min)
	cd /mnt
	sh ~/simulate_attack.sh

#Check Snapshot creation
	Cluster1::> snapshot show -snapshot Anti*
	Cluster1::> security anti-ransomware volume space show
	Cluster1::> security anti-ransomware volume show -volume vol1 -instance
	Cluster1::> security anti-ransomware volume attack generate-report -vserver prod -volume vol1 -dest-path prod:vol1

#generate ARW full report
	Cluster1::> security anti-ransomware volume attack generate-report -vserver prod -volume vol1 -dest-path prod:vol2

#create Snapmirror to Cloud config
	$session = new-pssession -ComputerName dc1
	Import-PSSession -Session $session -Module dnsserver -Prefix RemoteDNS |out-null
	Add-RemoteDNSDnsServerResourceRecordA -Name "s3" -ZoneName "demo.netapp.com" -AllowUpdateAny -IPv4Address "192.168.0.142" |out-null
	#on CL2
	object-store-server bucket create -bucket buck1 -comment "" -size 100g
	bucket policy add-statement -vserver svm1_cluster2 -bucket buck1 -effect allow -action GetObject,PutObject,DeleteObject,ListBucket,GetBucketAcl,GetObjectAcl,ListBucketMultipartUploads,ListMultipartUploadParts,GetObjectTagging,PutObjectTagging,DeleteObjectTagging,GetBucketLocation -principal *
	#on CL1
	sn object-store config create -object-store-name ntaps3 -usage data -owner snapmirror -provider-type ONTAP_S3 -server s3.demo.netapp.com -port 443 -is-ssl-enabled true -container-name buck1 -access-key SGWE431JS3LCKVLPGYWD -secret-password cAmAs54NQBAT06G7N_4Q94ikccNcS_XaE39CIcC1 -is-certificate-validation-enabled false
	sn policy add-rule -vserver prod -policy CloudYearly -snapmirror-label yearly -keep 4
	sn policy add-rule -vserver prod -policy CloudYearly -snapmirror-label monthly -keep 12
	sn policy add-rule -vserver prod -policy CloudYearly -snapmirror-label weekly -keep 6
	sn create -source-path prod:vol1 -destination-path ntaps3:/objstore/vol1_dst -schedule hourly -policy CloudYearly
	sn initialize -destination-path ntaps3:/objstore/vol1_dst

	#Check snapshot in the bucket
	sn show -destination-path *objstore* -fields destination-endpoint-uuid
	sn object-store endpoint snapshot show -object-store-name ntaps3 -endpoint-uuid <endpoint uuid>
#>

#Variables
$Logfilebase = "C:\LOD\FasInstall_log"
$maxlogfiles = 5
$maxlogfilesize = 2MB

$WorkingDir="C:\LOD\"
$netappusername = 'admin'
$netapppasswordfile = 'na_pwd_do_not_delete'

#/Variables
function LogWrite
{
	Param ([string]$logstring)
	$LogTime = Get-Date -Format "MM-dd-yyyy_hh-mm-ss"
	$Logfilename = $Logfilebase+"0"+".log"
	Write-Host "`n $($logstring)"
	"$LogTime - $logstring" | Out-File $Logfilename -Append -Encoding ASCII

	if ((Get-Item $Logfilename).Length -gt $maxlogfilesize) 
	{
		$lastlog = "$Logfilebase${maxlogfiles}"
		if (Test-Path $Logfilebase${maxlogfiles}) 
		{
			Remove-Item -Path $lastlog
		}
		for ($i=$maxlogfiles-1; $i -ge 0; $i--) 
		{
			if (Test-Path $Logfilebase${i}) 
			{
				$j = $i + 1 
				Rename-Item $Logfilebase${i} $Logfilebase${j}
			}
		}
	}
}
function Connect_Filer([string]$filernameSRC)
{
	#validate password file exists and convert to PS-Cred object
	$passwordfile = "$($PSScriptRoot)\$($netapppasswordfile)"
	if (!(Test-Path $passwordfile)) 
	{
			LogWrite "Encrypting NetApp Creds"
			write-host "Enter NetApp Cred:"
			Encrypt_password ($passwordfile)
	}
	
	$password = Get-Content $passwordfile | ConvertTo-SecureString 
	$cred = New-Object System.Management.Automation.PsCredential($netappusername,$password)
	$Ctrl = Connect-NcController $filernameSRC -Credential $cred  	
	if (-not $Ctrl) {
			Write-Host "ERROR: could not connect to NetApp controller: $filernameSRC" 
			return $false
	}  
}
function Encrypt_password ($passwordfile)
{
	Write-Host "`nPlease insert a user: $username with his relevant Password" 
	$cred = Get-Credential 
	$cred.Password | ConvertFrom-SecureString | Set-Content $passwordfile
	if (!(Test-Path $passwordfile) ) 
	{
		Write-Host "ERROR: password did not save" 
	}
	else 
	{
		Write-Host "password been hashed and saved to ($passwordfile)" 
	}
}

Connect_Filer $cluster

LogWrite "Creating SVM for CIFS ... "
$aggr=(Get-NcAggr |?{$_.AggrRaidAttributes.IsRootAggregate -eq $false})[0]
New-NcVserver -name prod -RootVolume prod_root -RootVolumeAggregate $aggr.name -RootVolumeSecurityStyle ntfs -NameServerSwitch file |out-null
LogWrite "Lif Creation: NAS"
New-NcNetInterface -name NAS -Vserver prod -role data -HomeNode $Cluster"-01" -HomePort e0f -DataProtocols nfs,cifs -Address 192.168.0.170 -Netmask 255.255.255.0	|out-null			
Enable-NcNfs -VserverContext prod
LogWrite "Configure DNS"
new-NcNetDns -Domains "demo.netapp.com"  -NameServers 192.168.0.253 -State enabled -VserverContext prod |out-null
New-NcNameMapping -Direction unix_win -Position 1 -Pattern "*" -Replacement DEMO\\Administrator -VserverContext prod |out-null
New-NcExportRule -Policy default -Index 1 -ClientMatch 0.0.0.0/0 -ReadOnlySecurityFlavor any -ReadWriteSecurityFlavor any -Protocol nfs -Anon 0 -SuperUserSecurityFlavor any -VserverContext prod |out-null
Add-NcCifsServer -Name prod -Domain demo.netapp.com -AdminUsername Administrator -AdminPassword "Netapp1!" -VserverContext prod |out-null
New-NcVol -Name vol1 -Aggregate $aggr.name -JunctionPath /vol1 -SecurityStyle ntfs -SpaceReserve none -Size 30g -VserverContext prod |out-null
New-NcVol -Name vol2 -Aggregate $aggr.name -JunctionPath /vol2 -SecurityStyle ntfs -SpaceReserve none -Size 36g -VserverContext prod |out-null
Add-NcCifsShare -Name vol1 -Path /vol1 -VserverContext prod
Add-NcCifsShare -Name vol2 -Path /vol2 -VserverContext prod
#setup DNS name for iso SVM
Logwrite "Adding Prod DNS entry to match 192.168.0.170"
$session = new-pssession -ComputerName dc1
Import-PSSession -Session $session -Module dnsserver -Prefix RemoteDNS |out-null
Add-RemoteDNSDnsServerResourceRecordA -Name "prod" -ZoneName "demo.netapp.com" -AllowUpdateAny -IPv4Address "192.168.0.170" |out-null

#get first peer cluster name
$peercluster=(Get-NcClusterPeer)[0]
$CurrentNcController = $null
#Connect to cluster peer 
Connect_Filer $peercluster.ClusterName

New-NcVserver -name prod_dp -Subtype dp-destination |out-null
New-NcVserverPeer -Vserver prod_dp -PeerVserver prod -Application snapmirror -PeerCluster $cluster
$peered=$false
while ($peered -eq $false)
{
    $vserverpeer=Get-NcVserverPeer -Vserver prod_dp
    if (($vserverpeer.Peerstate).tolower() -eq "peered")
    {
        Logwrite "vserver are peered"
        $peered = $true
    }
    else
    {
        Logwrite "vserver are not peered yet ... waiting 5 seconds"
        sleep 5
    }
}
Logwrite "Creating SVM-DR relationship"
New-NcSnapmirror -Destination prod_dp: -Source prod: -Schedule 5min -PreserveIdentity:$true |out-null
Invoke-NcSnapmirrorInitialize -Destination prod_dp: |out-null
$snapmirrored = $false
while ($snapmirrored -eq $false)
{
    $SMstate=Get-NcSnapmirror -Destination prod_dp:
    if (($SMstate.MirrorState).tolower() -eq "snapmirrored")
    {
        Logwrite "Baseline Done !!"
        $snapmirrored = $true
    }
    else
    {
        Logwrite "Baseline in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
        sleep 5
    }
}

Logwrite "Configure Snaplock Compliance clock"
$nodes=get-NcNode
foreach ($node in $nodes)
{
    Set-NcSnaplockComplianceClock -Node $node.node -confirm:$false |out-null
}

Logwrite "Creating SVM for immutable backup"

$aggr=(Get-NcAggr |?{$_.AggrRaidAttributes.IsRootAggregate -eq $false})[0]
New-NcVserver -name prod_bkp -RootVolume prod_bkp_root -RootVolumeAggregate $aggr.name -RootVolumeSecurityStyle ntfs -NameServerSwitch file |out-null
New-NcVserverPeer -Vserver prod_bkp -PeerVserver prod_dp -Application snapmirror -PeerCluster $peercluster.ClusterName
LogWrite "Create DP volume for all volumes from source SVM"
$vols=get-ncvol -Vserver prod_dp | ?{$_.VolumeStateAttributes.IsVserverRoot -eq $false}
Logwrite "You will need to create volume using the bellow output :"
write "###Cmd to Run on Cluster1" |Out-File -Append c:\LOD\CmdsToRunOnCluster1.txt
write "###Cmd to Run on Cluster2" |Out-File -Append c:\LOD\CmdsToRunOnCluster2.txt
foreach ($vol in $vols)
{
    $sizeinGB=$vol.TotalSize/1024/1024/1024
    write "vol modify -vserver prod -volume $($vol.name) -anti-ransomware-state dry-run" |Out-File -Append c:\LOD\CmdsToRunOnCluster1.txt
	write "vol create -vserver prod_bkp  -volume $($vol.name)_bkp -aggregate $($aggr.name) -snaplock-type enterprise -type DP -size $($sizeinGB)g" |Out-File -Append c:\LOD\CmdsToRunOnCluster2.txt
    write "snapmirror create -source-path prod_dp:$($vol.name) -destination-path prod_bkp:$($vol.name)_bkp -policy XDPDefault -schedule 5min " |Out-File -Append c:\LOD\CmdsToRunOnCluster2.txt
	write "snapmirror initialize -destination-path prod_bkp:$($vol.name)_bkp" |Out-File -Append c:\LOD\CmdsToRunOnCluster2.txt
}
#opening the cli file
c:\LOD\CmdsToRunOnCluster1.txt
c:\LOD\CmdsToRunOnCluster2.txt
putty cluster1
putty cluster2

