# Author  : David BENADIBA
# Title   : RestampSnapShotLockVault.ps1
# Version : v0.1
#Usage: .\RestampSnapShotLockVault.ps1 -Cluster <Cluster Name / IP> 
# The script is going to search for all snaplock snapshots and validate that snaplock expiry date match the willing retention (Cf variable)

Param(
	[Parameter(Mandatory=$true)][string]$Cluster
	)

##Variables
#Retention Variable
$hourlyRT = 24
$dailyRT = 7
$weeklyRT = 52
#Snap Label
$smlabelhourly = "hourly"
$smlabeldaily = "daily"
$smlabelweekly = "weekly"
#Creds
$netappusername = 'admin'
$netapppasswordfile = 'na_pwd_do_not_delete'
$passwordfile = "$($PSScriptRoot)\$($netapppasswordfile)"

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

function Connect_Filer([string]$filernameSRC)
{
	#validate password file exists and convert to PS-Cred object
	$passwordfile = "$($PSScriptRoot)\$($netapppasswordfile)"
	if (!(Test-Path $passwordfile)) 
	{
			write-host "Encrypting NetApp Creds"
			write-host "Enter NetApp Cred:"
			Encrypt_password ($passwordfile)
	}
	
	$password = Get-Content $passwordfile | ConvertTo-SecureString 
	$cred = New-Object System.Management.Automation.PsCredential("admin",$password)
	$Ctrl = Connect-NcController $filernameSRC -Credential $cred  	
	if (-not $Ctrl) {
			Write-Host "ERROR: could not connect to NetApp controller: $filernameSRC" 
			return $false
	}  
}



if (!(Test-Path $passwordfile)) 
{
	write-host "Enter NetApp Cred:"
	Encrypt_password ($passwordfile)
}

$password = Get-Content $passwordfile | ConvertTo-SecureString 
$cred = New-Object System.Management.Automation.PsCredential($netappusername,$password)

$hdrs = @{}
$hdrs.Add("Accept","application/hal+json")
#$hdrs.Add("Authorization", "Basic $TOKEN")

## Accept non trusted certs (Pure Powershell)
$code= @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
Add-Type -TypeDefinition $code -Language CSharp
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
##

Connect_Filer $cluster

#Get all Snaplocked volumes
$vols=get-ncvol |?{$_.VolumeSnaplockAttributes.SnaplockType -ne "non_snaplock" -and $_.VolumeStateAttributes.IsNodeRoot -eq $false -and $_.VolumeMirrorAttributes.IsDataProtectionMirror}

foreach ($vol in $vols)
{
	#Get Some info first (Volume UUID, SVM UUID, Snapshots)
	$UriVolume = "https://"+$Cluster+"/api/storage/volumes?svm.name=$($vol.vserver)&name=$($vol.name)&fields=uuid,state"
	$Volinfo=Invoke-RestMethod -Method GET -Uri $UriVolume -headers $hdrs -credential $cred
	$UriSVM = "https://"+$Cluster+"/api/svm/svms?name=$($vol.vserver)&return_records=true&return_timeout=15"
	$SVMInfo=Invoke-RestMethod -Method GET -Uri $UriSVM -headers $hdrs -credential $cred
	$UriSnapshots="https://$($Cluster)/api/storage/volumes/$($Volinfo.records.uuid)/snapshots?return_records=true&return_timeout=15&fields=uuid,name,svm.name,svm.uuid,volume.name,snapmirror_label,snaplock_expiry_time,create_time"
	$snaps=Invoke-RestMethod -Method GET -Uri $UriSnapshots -headers $hdrs -credential $cred
	
	#$snaps=Get-NcSnapshot -Volume $vol.name -Vserver $vol.vserver |?{$_.SnaplockExpiryTimeDT -ne $null}

	foreach ($snap in $snaps.records)
	{
		#write-host "Volume Name: $vol - - snap name : $($snap.name) - - Label: $($snap.snapmirror_label) - - Created time : $($snap.create_time) - - - Snaplock Expiry Time: $($snap.snaplock_expiry_time)"
		#let's find if snapshot got correct retention 
		if (($snap.snapmirror_label).tolower() -eq $smlabelhourly.tolower())
		{
			write-host "Hourly snap name : $($snap.name) - - Let's check is snapshot expiry time is over"
			#normalize DT
			$Creation=($snap.create_time).Split("+")[0]
			$CreationDT=[datetime]::parseexact($Creation,'yyyy-MM-ddTHH:mm:ss', $null)
			$SnapLockExpiryTime=($snap.snaplock_expiry_time).Split("+")[0]
			$SnapLockExpiryTimeDT=[datetime]::parseexact($SnapLockExpiryTime,'yyyy-MM-ddTHH:mm:ss', $null)
			$CreationDateAfterRetention=($CreationDT).Addhours($hourlyRT)
			if ($CreationDateAfterRetention -le $SnapLockExpiryTimeDT )
			{
				write-host "expiry = $($SnapLockExpiryTimeDT) --- Created = $($CreationDT) --- Created After Retention : $($CreationDateAfterRetention)"
			}
			else
			{
				write-host "expiry = $($SnapLockExpiryTimeDT) --- Created = $($CreationDT) --- Created After Retention : $($CreationDateAfterRetention)" -foregroundcolor RED
				#extend retention for hourly snaps
				Set-NcSnapshotSnaplockExpTime -Volume $vol -Snapshot $snap.name -Expirytime $CreationDateAfterRetention -VserverContext $vol.vserver
			}
		}
		if (($snap.snapmirror_label).tolower() -eq $smlabeldaily.tolower())
		{
			write-host "Daily snap name : $($snap.name) Let's check is snapshot expiry time is over"
			#normalize DT
			$Creation=($snap.create_time).Split("+")[0]
			$CreationDT=[datetime]::parseexact($Creation,'yyyy-MM-ddTHH:mm:ss', $null)
			$SnapLockExpiryTime=($snap.snaplock_expiry_time).Split("+")[0]
			$SnapLockExpiryTimeDT=[datetime]::parseexact($SnapLockExpiryTime,'yyyy-MM-ddTHH:mm:ss', $null)
			$CreationDateAfterRetention=($CreationDT).AddDays($dailyRT)
			if ($CreationDateAfterRetention -le $SnapLockExpiryTimeDT )
			{
				write-host "expiry = $($SnapLockExpiryTimeDT) --- Created = $($CreationDT) --- Created After Retention : $($CreationDateAfterRetention)"
			}
			else
			{
				write-host "expiry = $($SnapLockExpiryTimeDT) --- Created = $($CreationDT) --- Created After Retention : $($CreationDateAfterRetention)" -foregroundcolor RED
				#extend retention for daily snaps
				Set-NcSnapshotSnaplockExpTime -Volume $vol -Snapshot $snap.name -Expirytime $CreationDateAfterRetention -VserverContext $vol.vserver
			}
		}
		if (($snap.snapmirror_label).tolower() -eq $smlabelweekly.tolower())
		{
			write-host "Weekly snap name : $($snap.name) Let's check is snapshot expiry time is over"
			#normalize DT
			$Creation=($snap.create_time).Split("+")[0]
			$CreationDT=[datetime]::parseexact($Creation,'yyyy-MM-ddTHH:mm:ss', $null)
			$SnapLockExpiryTime=($snap.snaplock_expiry_time).Split("+")[0]
			$SnapLockExpiryTimeDT=[datetime]::parseexact($SnapLockExpiryTime,'yyyy-MM-ddTHH:mm:ss', $null)
			#weekly to days
			$weeklyRTDays=7*$weeklyRT
			$CreationDateAfterRetention=($CreationDT).Adddays($weeklyRTDays)
			if ($CreationDateAfterRetention -le $SnapLockExpiryTimeDT )
			{
				write-host "expiry = $($SnapLockExpiryTimeDT) --- Created = $($CreationDT) --- Created After Retention : $($CreationDateAfterRetention)"
			}
			else
			{
				write-host "expiry = $($SnapLockExpiryTimeDT) --- Created = $($CreationDT) --- Created After Retention : $($CreationDateAfterRetention)" -foregroundcolor RED
				#extend retention for daily snaps
				Set-NcSnapshotSnaplockExpTime -Volume $vol -Snapshot $snap.name -Expirytime $CreationDateAfterRetention -VserverContext $vol.vserver
			}
		}
	}
}