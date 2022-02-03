Param(
	[Parameter(Mandatory=$true)][string]$Cluster
    )
<# 
Comments:
    This script will take Weekly, Monthly and Yearly snapshot on source then delete Monthly and Yearly snap from the source volume.
    This is working only on SM to Cloud environment
 
    Script is looking for date to select which backup type:
    --> 1st Sunday of the year à Yearly snapshot + Monthly Snapshot + Weekly Snapshot
    --> 1st Sunday of the month à Monthly Snapshot +Weekly snapshot
    --> Sunday à Weekly Snapshot

Relation type :
    Prod Volume (RW) >>> SM Cloud >>> S3Bucket

Note:
- This script will not work if you have cascaded environement (RW >> SnapVault >> DP >> Snapmirror to Cloud >> Bucket)
- This script requires :
    - NetApp Powershell Toolkit (v4.2 +)
    - Cluster credentials (right to create snapshot / push snapmirror)

Usage: 
    smcloud_yearlysnap.ps1 -cluster <DNS name of the cluster>
        ex: smcloud_yearlysnap.ps1 -cluster cluster1

#>
#Variables
$Logfilebase = "C:\LOD\FasInstall_log"
$maxlogfiles = 5
$maxlogfilesize = 2MB

$WorkingDir="C:\LOD\"
$netappusername = 'admin'
$netapppasswordfile = 'na_pwd_do_not_delete'

$maxweeklysnapcount = 3

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
$date=get-date
# - Get the snapmirror 2 Cloud relationships  
$relations=Get-NcSnapmirror |?{$_.DestinationLocation -match "objstore"}
#Let's check if we are the 1st Sunday of the year;)
if ($date.Day -le 7 -and $date.DayOfWeek -eq "Sunday" -and $date.month -eq "1") 
{
	Logwrite "First Sunday of the year ... Let's take also a yearly snapshot"
	$yearly=$true
} 
if ($date.Day -le 7 -and $date.DayOfWeek -eq "Sunday" ) 
{
	Logwrite "First Sunday of the month ... Let's take also a monthly snapshot"
	$monthly=$true
} 
if ($date.DayOfWeek -eq "Sunday" ) 
{
	Logwrite "It is Sunday ... Let's take also a weekly snapshot"
	$weekly=$true
} 
else
{
	Logwrite "Not the first Sunday of the year nor of the month nor of the week ;)"
	Logwrite "It is not backup day. Just displaying Lag time"
	$notsunday=$true
}
#Create a rndom number for snapshot suffix
$rndnumber = Get-Random -Minimum 1 -Maximum 200
foreach ($relation in $relations)
{
	if ($monthly -eq $true)
	{
		# - Create a snap on the production volume called Yearly and match with SM Label Monthly
		Logwrite "It is the first Sunday of the month. Taking a Monthly snapshot"
		$MonthlySnapName="Monthly_"+$date.month.tostring()+"_"+$rndnumber.ToString()
		$monthlysnap=New-NcSnapshot -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $MonthlySnapName -SnapmirrorLabel monthly
		Logwrite "Monthly snapshot name = $($monthlysnap.name)"
		if ($yearly -eq $true)
		{
			Logwrite "It is the first sunday of the year. Taking a yearly snapshot"
			$YearlySnapName="Yearly_"+$date.year.tostring()+"_"+$rndnumber.ToString()
			$yearlysnap=New-NcSnapshot -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $YearlySnapName -SnapmirrorLabel yearly
			Logwrite "Yearly snapshot name = $($yearlysnap.name)"
		}
		Logwrite "Force replication to : $($relation.DestinationLocation) to push newly created snapshots"
		Invoke-NcSnapmirrorUpdate -Destination $relation.DestinationLocation |out-null
		Logwrite "Let's check replication status"
		$snapmirrored = $false
		while ($snapmirrored -eq $false)
		{
			$SMstate=Get-NcSnapmirror -Destination $relation.DestinationLocation
			if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
			{
				Logwrite "Update Done !! --- Common Snapshot = $($SMstate.NewestSnapshot) "
				$snapmirrored = $true
			}
			else
			{
				Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
				sleep 5
			}
		}
	}
	if ($weekly -eq $true)
	{
		#Once ok then Create another snapshot like a weekly
		Logwrite "It is Sunday. Taking a Weekly snapshot"
		$WeeklySnapName="Weekly_"+$date.month.tostring()+"_"+$rndnumber.ToString()
		$weeklysnap=New-NcSnapshot -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $WeeklySnapName -SnapmirrorLabel weekly
		
		Logwrite "Force replication to : $($relation.DestinationLocation) to push newly weekly snapshots"
		Invoke-NcSnapmirrorUpdate -Destination $relation.DestinationLocation |out-null
		Logwrite "Let's check replication status"
		$snapmirrored = $false
		while ($snapmirrored -eq $false)
		{
			$SMstate=Get-NcSnapmirror -Destination $relation.DestinationLocation
			if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
			{
				Logwrite "Update Done !! --- Common Snapshot = $($SMstate.NewestSnapshot) "
				$snapmirrored = $true
			}
			else
			{
				Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
				sleep 5
			}
		}
		if ($monthly -eq $true)
		{
			Logwrite "Let's clean monthly snapshot"
			Logwrite "Force replication to : $($relation.DestinationLocation) to push newly weekly snapshots"
			Invoke-NcSnapmirrorUpdate -Destination $relation.DestinationLocation |out-null
			Logwrite "Let's check replication status"
			$snapmirrored = $false
			while ($snapmirrored -eq $false)
			{
				$SMstate=Get-NcSnapmirror -Destination $relation.DestinationLocation
				if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
				{
					Logwrite "Update Done !! --- Common Snapshot = $($SMstate.NewestSnapshot) "
					$snapmirrored = $true
				}
				else
				{
					Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
					sleep 5
				}
			}
			$NewSMstate=Get-NcSnapmirror -Destination $relation.DestinationLocation
			if ($NewSMstate -ne $monthlysnap.name)
			{
				Logwrite "Monthly Snapshot is unlocked. We can remove it"
				Remove-NcSnapshot -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $monthlysnap.name -confirm:$false |out-null
			}
		}
		if ($yearly -eq $true)
		{
			Logwrite "Let's clean Yearly Snapshot "
			$NewSMstate=Get-NcSnapmirror -Destination $relation.DestinationLocation
			if ($NewSMstate -ne $yearlysnap.name)
			{
				Logwrite "Yearly Snapshot is unlocked. We can remove it"
				Remove-NcSnapshot -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $yearlysnap.name -confirm:$false |out-null
			}
		}
		Logwrite "Cleaning old weekly snapshots "
		#listing all weekly snapshots 
		$snaps=get-ncsnapshot -vserver $relation.sourcevserver -volume $relation.sourcevolume |?{$_.name -match "Weekly" -and $_.Dependency -ne "snapmirror"} |Sort-Object -Property Created -Descending
		if ($snaps.count -gt $maxweeklysnapcount)
		{
			#Select the older snap from the list
			$snaptodelete = $snaps[-1]
			LogWrite "Deleting snapshot : $($snaptodelete.name) created on : $($snaptodelete.created)"
			Remove-NcSnapshot -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $snaptodelete.name -confirm:$false |out-null
		}
	}

	$relation
	
}
