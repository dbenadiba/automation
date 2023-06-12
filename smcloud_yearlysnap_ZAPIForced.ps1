Param(
	[Parameter(Mandatory=$true)][string]$Cluster,
	[Parameter(Mandatory=$false)][switch]$Testdebug,
	[Parameter(Mandatory=$false)][switch]$yearly,
	[Parameter(Mandatory=$false)][switch]$monthly,
	[Parameter(Mandatory=$false)][switch]$weekly
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
    PROD VOLUME(RW) >>> SM Cloud >>> S3Bucket
	PROD VOLUME (R/W) >>> Volume Snapmirror (MirrorAllSnapshots) >>> DR VOLUME (R/O) >>> SM Cloud >>> S3Bucket
Note:
- This script will not work if you have cascaded environement (RW >> SnapVault >> DP >> Snapmirror to Cloud >> Bucket)
- This script requires :
    - NetApp Powershell Toolkit (v4.2 +)
    - Cluster credentials (right to create snapshot / push snapmirror)
Usage: 
    smcloud_yearlysnap.ps1 -cluster <DNS name of the cluster>
        ex: smcloud_yearlysnap.ps1 -cluster cluster1
		debug (force backup on another day than sunday) : 
			#Create a Weekly Snapshot
			smcloud_yearlysnap.ps1 -cluster cluster1 -Testdebug -weekly
			#Create a Monthly and a Weekly Snapshot
			smcloud_yearlysnap.ps1 -cluster cluster1 -Testdebug -monthly -weekly 
			#Create a Yearly, a Monthly and a Weekly Snapshot
			smcloud_yearlysnap.ps1 -cluster cluster1 -Testdebug -yearly -monthly -weekly
		
#>

#Variables
$Logfilebase = "C:\LOD\SMC_Monthly_log"
$maxlogfiles = 5
$maxlogfilesize = 50KB

$WorkingDir="C:\LOD\"
$netappusername = 'admin'
$netapppasswordfile = '_na_pwd_do_not_delete'

$weeklysnaplabel = "sv_weekly"
$monthlysnaplabel = "sv_monthly"
$yearlysnaplabel = "sv_yearly"

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
		$lastlog = "$Logfilebase${maxlogfiles}.log"
		if (Test-Path "$Logfilebase${maxlogfiles}.log") 
		{
			Remove-Item -Path $lastlog
		}
		for ($i=$maxlogfiles-1; $i -ge 0; $i--) 
		{
			if (Test-Path "$Logfilebase${i}.log") 
			{
				$j = $i + 1 
				Rename-Item "$Logfilebase${i}.log" "$Logfilebase${j}.log"
			}
		}
	}
}
function Connect_Filer([string]$filernameSRC)
{
	#validate password file exists and convert to PS-Cred object
	$netapppasswordfile = $filernameSRC+$netapppasswordfile
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
$date=get-date
Connect_Filer $cluster
Logwrite "_+_+_+_+_+_+_+_ $($date)_+_+_+_+_+_+_+_ "
# - Get the snapmirror 2 Cloud relationships  
$relations=Get-NcSnapmirror -Zapicall |?{$_.DestinationLocation -match "objstore"}
#Let's check if we are the 1st Sunday of the year;)
if (!$Testdebug)
{
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
}


#Create a rndom number for snapshot suffix
$rndnumber = Get-Random -Minimum 1 -Maximum 200
foreach ($relation in $relations)
{
	if ($monthly -eq $true)
	{
		# - Create a snap on the production volume called Yearly and match with SM Label Monthly
		Logwrite "Searching for Source volume "
		$relDP = Get-NcSnapmirror -Zapicall|?{$_.DestinationLocation -eq "$($relation.sourcevserver):$($relation.sourcevolume)"}
		if ($relDP)
		{
			$peering=Get-NcVserverPeer -zapicall -PeerVserver $relDP.sourcevserver
			$peering=$peering[0]
			if ($relDP.PolicyType -eq "vault")
			{
				$vault = $true
				Logwrite "SnapVault Cascading detected !!! Source volume = $($relDP.sourcevolume) Source SVM: $($relDP.sourcevserver) Source Cluster: $($peering.PeerCluster)" 
				#checking snapmirror policy
				$Policy=Get-NcSnapmirrorPolicy -PolicyName $relDP.policy -Zapicall
				if ($Policy.SnapmirrorPolicyRules.snapmirrorlabel -contains $weeklysnaplabel -and $Policy.SnapmirrorPolicyRules.snapmirrorlabel -contains $monthlysnaplabel -and $Policy.SnapmirrorPolicyRules.snapmirrorlabel -contains $yearlysnaplabel)
				{
					Logwrite "SnapVault Policy in used: $($relDP.policy) also replicate monthly and yearly snapshot to secondary"
					$MonthlySnapName="Monthly_"+$date.month.tostring()+"_"+$rndnumber.ToString()
					Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
					$CurrentNcController = $null
					Connect_Filer $peering.PeerCluster
					$monthlysnap=New-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $MonthlySnapName -SnapmirrorLabel $monthlysnaplabel
					Logwrite "Monthly snapshot name = $($monthlysnap.name)"
					if ($yearly -eq $true)
					{
						Logwrite "It is the first sunday of the year. Taking a yearly snapshot"
						$YearlySnapName="Yearly_"+$date.year.tostring()+"_"+$rndnumber.ToString()
						$yearlysnap=New-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $YearlySnapName -SnapmirrorLabel $yearlysnaplabel
						Logwrite "Yearly snapshot name = $($yearlysnap.name)"
					}
					Logwrite "Force replication to : $($relDP.DestinationLocation) to push newly created snapshots to the DRP Cluster"
					$CurrentNcController = $null
					Connect_Filer $cluster
					Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relDP.DestinationLocation |out-null
					Logwrite "Let's check replication status"
					$snapmirrored = $false
					while ($snapmirrored -eq $false)
					{
						$SMstate=Get-NcSnapmirror -Zapicall -Destination $relDP.DestinationLocation
						if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
						{
							Logwrite "Update Done !! --- Mirror State = $($SMstate.MirrorState) "
							$snapmirrored = $true
						}
						else
						{
							Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
							sleep 5
						}
					}
					Logwrite "Force SMC replication to : $($relation.DestinationLocation) to push newly created snapshots"
					Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relation.DestinationLocation |out-null
					Logwrite "Let's check replication status"
					$snapmirrored = $false
					while ($snapmirrored -eq $false)
					{
						$SMstate=Get-NcSnapmirror -Zapicall -Destination $relation.DestinationLocation
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
				else
				{
					Logwrite "SnapVault Policy in used: $($relDP.policy) does NOT replicate monthly and yearly snapshot to secondary... Exiting !"
					exit 0
				}
			}
			else
			{
				Logwrite "SnapMirror Cascading detected !!! Source volume = $($relDP.sourcevolume) Source SVM: $($relDP.sourcevserver) Source Cluster: $($peering.PeerCluster)" 
				$MonthlySnapName="Monthly_"+$date.month.tostring()+"_"+$rndnumber.ToString()
				Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
				$CurrentNcController = $null
				Connect_Filer $peering.PeerCluster
				$monthlysnap=New-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $MonthlySnapName -SnapmirrorLabel $monthlysnaplabel
				Logwrite "Monthly snapshot name = $($monthlysnap.name)"
				if ($yearly -eq $true)
				{
					Logwrite "It is the first sunday of the year. Taking a yearly snapshot"
					$YearlySnapName="Yearly_"+$date.year.tostring()+"_"+$rndnumber.ToString()
					$yearlysnap=New-NcSnapshot -Zapicall  -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $YearlySnapName -SnapmirrorLabel $yearlysnaplabel
					Logwrite "Yearly snapshot name = $($yearlysnap.name)"
				}
				Logwrite "Force replication to : $($relDP.DestinationLocation) to push newly created snapshots to the DRP Cluster"
				$CurrentNcController = $null
				Connect_Filer $cluster
				Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relDP.DestinationLocation |out-null
				Logwrite "Let's check replication status"
				$snapmirrored = $false
				while ($snapmirrored -eq $false)
				{
					$SMstate=Get-NcSnapmirror -Zapicall -Destination $relDP.DestinationLocation
					if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
					{
						Logwrite "Update Done !! --- Mirror State = $($SMstate.MirrorState) "
						$snapmirrored = $true
					}
					else
					{
						Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
						sleep 5
					}
				}
				Logwrite "Force SMC replication to : $($relation.DestinationLocation) to push newly created snapshots"
				Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relation.DestinationLocation |out-null
				Logwrite "Let's check replication status"
				$snapmirrored = $false
				while ($snapmirrored -eq $false)
				{
					$SMstate=Get-NcSnapmirror -Zapicall -Destination $relation.DestinationLocation
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
		}
		else
		{
			Logwrite "It is the first Sunday of the month. Taking a Monthly snapshot"
			$MonthlySnapName="Monthly_"+$date.month.tostring()+"_"+$rndnumber.ToString()
			$monthlysnap=New-NcSnapshot -Zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $MonthlySnapName -SnapmirrorLabel $monthlysnaplabel
			Logwrite "Monthly snapshot name = $($monthlysnap.name)"
			if ($yearly -eq $true)
			{
				Logwrite "It is the first sunday of the year. Taking a yearly snapshot"
				$YearlySnapName="Yearly_"+$date.year.tostring()+"_"+$rndnumber.ToString()
				$yearlysnap=New-NcSnapshot -Zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $YearlySnapName -SnapmirrorLabel $yearlysnaplabel
				Logwrite "Yearly snapshot name = $($yearlysnap.name)"
			}
			Logwrite "Force replication to : $($relation.DestinationLocation) to push newly created snapshots"
			Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relation.DestinationLocation |out-null
			Logwrite "Let's check replication status"
			$snapmirrored = $false
			while ($snapmirrored -eq $false)
			{
				$SMstate=Get-NcSnapmirror -Zapicall -Destination $relation.DestinationLocation
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
		
	}
	if ($weekly -eq $true)
	{
		#Once ok then Create another snapshot like a weekly
		Logwrite "Searching for Source volume "
		$relDP = Get-NcSnapmirror -Zapicall |?{$_.DestinationLocation -eq "$($relation.sourcevserver):$($relation.sourcevolume)"}
		if ($relDP)
		{
			$peering=Get-NcVserverPeer -Zapicall -PeerVserver $relDP.sourcevserver
			$peering=$peering[0]
			Logwrite "Cascading detected !!! Source volume = $($relDP.sourcevolume) Source SVM: $($relDP.sourcevserver) Source Cluster: $($peering.PeerCluster)"
			Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
			$CurrentNcController = $null
			Connect_Filer $peering.PeerCluster
			
			Logwrite "It is Sunday. Taking a Weekly snapshot"
			$WeeklySnapName="Weekly_"+$date.day.tostring()+"_"+$rndnumber.ToString()
			$weeklysnap=New-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $WeeklySnapName -SnapmirrorLabel $weeklysnaplabel
			
			#listing all weekly snapshots 
			$snaps=get-ncsnapshot -Zapicall -vserver $relDP.sourcevserver -volume $relDP.sourcevolume |?{$_.name -match "Weekly" -and $_.Dependency -ne "snapmirror"} |Sort-Object -Property Created -Descending
			if ($snaps.count -gt $maxweeklysnapcount)
			{
				#Select the older snap from the list
				$snaptodelete = $snaps[-1]
				LogWrite "Deleting snapshot : $($snaptodelete.name) created on : $($snaptodelete.created)"
				Remove-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $snaptodelete.name -confirm:$false |out-null
			}
			Logwrite "Force replication to : $($relDP.DestinationLocation) to push newly created snapshots to the DRP Cluster"
			$CurrentNcController = $null
			Connect_Filer $cluster
			
			Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relDP.DestinationLocation |out-null
			Logwrite "Let's check replication status"
			$snapmirrored = $false
			while ($snapmirrored -eq $false)
			{
				$SMstate=Get-NcSnapmirror -zapicall -Destination $relDP.DestinationLocation
				if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
				{
					Logwrite "Update Done !! --- Mirror State = $($SMstate.MirrorState) "
					$snapmirrored = $true
				}
				else
				{
					Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
					sleep 5
				}
			}
			Logwrite "Force SMC replication to : $($relation.DestinationLocation) to push newly created snapshots"
			Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relation.DestinationLocation |out-null
			Logwrite "Let's check replication status"
			$snapmirrored = $false
			while ($snapmirrored -eq $false)
			{
				$SMstate=Get-NcSnapmirror -Zapicall -Destination $relation.DestinationLocation
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
				Logwrite "Let's clean monthly snapshot on source Cluster"
				Logwrite "Force replication to : $($relation.DestinationLocation) to push newly weekly snapshots"
				Invoke-NcSnapmirrorUpdate -Zapicall -Destination $relation.DestinationLocation |out-null
				Logwrite "Let's check replication status"
				$snapmirrored = $false
				while ($snapmirrored -eq $false)
				{
					$SMstate=Get-NcSnapmirror -Zapicall -Destination $relation.DestinationLocation
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
				$NewSMstate=Get-NcSnapmirror -Zapicall -Destination $relation.DestinationLocation
				if ($NewSMstate.NewestSnapshot -ne $monthlysnap.name)
				{
					if ($vault -eq $true)
					{
						Logwrite "Relationship is using type Vault... We will remove the monthly snapshots from the primary and the secondary"
						Logwrite "Monthly Snapshot is unlocked. We can remove it"
						Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
						$CurrentNcController = $null
						Connect_Filer $peering.PeerCluster
						Logwrite "Removing snapshot: $($monthlysnap.name) from volume : $($relDP.sourcevolume) on Cluster : $($peering.PeerCluster)"
						Remove-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $monthlysnap.name -IgnoreOwners -confirm:$false |out-null
						$CurrentNcController = $null
						Logwrite "Removing snapshot: $($monthlysnap.name) from volume : $($relation.sourcevolume) on Cluster : $($cluster)"
						Connect_Filer $cluster
						#start-sleep -second 5
						Remove-NcSnapshot -Zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $monthlysnap.name -confirm:$false |out-null
						
					}
					else
					{
						Logwrite "Monthly Snapshot is unlocked. We can remove it"
						Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
						$CurrentNcController = $null
						Connect_Filer $peering.PeerCluster
						Logwrite "Removing snapshot: $($monthlysnap.name) from volume : $($relDP.sourcevolume) on Cluster : $($peering.PeerCluster)"
						Remove-NcSnapshot -Zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $monthlysnap.name -confirm:$false |out-null
						$CurrentNcController = $null
						Logwrite "Force SnapMirror update "
						Connect_Filer $cluster
						Invoke-NcSnapmirrorUpdate -zapicall -Destination $relDP.DestinationLocation |out-null
						Logwrite "Let's check replication status"
						$snapmirrored = $false
						while ($snapmirrored -eq $false)
						{
							$SMstate=Get-NcSnapmirror -zapicall -Destination $relDP.DestinationLocation
							if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
							{
								Logwrite "Update Done !! --- Mirror State = $($SMstate.MirrorState) "
								$snapmirrored = $true
							}
							else
							{
								Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
								sleep 5
							}
						}
					}
					
				}
			}
			if ($yearly -eq $true)
			{
				Logwrite "Let's clean Yearly Snapshot "
				if ($CurrentNcController = $null)
				{
					Connect_Filer $cluster
				}
				$NewSMstate=Get-NcSnapmirror -zapicall -Destination $relation.DestinationLocation
				if ($NewSMstate.NewestSnapshot -ne $yearlysnap.name)
				{
					if ($vault -eq $true)
					{
						Logwrite "Relationship is using type Vault... We will remove the yearly snapshots from the primary and the secondary"
						Logwrite "Yearly Snapshot is unlocked. We can remove it"
						Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
						$CurrentNcController = $null
						Connect_Filer $peering.PeerCluster
						Logwrite "Removing snapshot: $($yearlysnap.name) from volume : $($relDP.sourcevolume) on Cluster : $($peering.PeerCluster)"
						Remove-NcSnapshot -zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $yearlysnap.name -IgnoreOwners -confirm:$false |out-null
						$CurrentNcController = $null
						Logwrite "Removing snapshot: $($yearlysnap.name) from volume : $($relation.sourcevolume) on Cluster : $($cluster)"
						Connect_Filer $cluster
						Remove-NcSnapshot -zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $yearlysnap.name -confirm:$false |out-null
					}
					else
					{
						Logwrite "Yearly Snapshot is unlocked. We can remove it"
						Logwrite "Connecting to peer cluster : $($peering.PeerCluster)"
						$CurrentNcController = $null
						Connect_Filer $peering.PeerCluster
						Logwrite "Removing snapshot: $($yearlysnap.name) from volume : $($relDP.sourcevolume) on Cluster : $($peering.PeerCluster)"
						Remove-NcSnapshot -zapicall -Volume $relDP.sourcevolume -VserverContext $relDP.sourcevserver -Snapshot $yearlysnap.name -confirm:$false |out-null
						$CurrentNcController = $null
						Connect_Filer $cluster
						Invoke-NcSnapmirrorUpdate -zapicall -Destination $relDP.DestinationLocation |out-null
						Logwrite "Let's check replication status"
						$snapmirrored = $false
						while ($snapmirrored -eq $false)
						{
							$SMstate=Get-NcSnapmirror -zapicall -Destination $relDP.DestinationLocation
							if (($SMstate.status).tolower() -eq "idle" -and $SMstate.IsHealthy -eq $true)
							{
								Logwrite "Update Done !! --- Mirror State = $($SMstate.MirrorState) "
								$snapmirrored = $true
							}
							else
							{
								Logwrite "Update in progress (status = $($SMstate.MirrorState)) ... waiting 5 seconds"
								sleep 5
							}
						}
					}
				}
			}
			
		}
		else
		{
			Logwrite "It is Sunday. Taking a Weekly snapshot"
			$WeeklySnapName="Weekly_"+$date.day.tostring()+"_"+$rndnumber.ToString()
			$weeklysnap=New-NcSnapshot -zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $WeeklySnapName -SnapmirrorLabel $weeklysnaplabel
			Logwrite "Force replication to : $($relation.DestinationLocation) to push newly weekly snapshots"
			Invoke-NcSnapmirrorUpdate -zapicall -Destination $relation.DestinationLocation |out-null
			Logwrite "Let's check replication status"
			$snapmirrored = $false
			while ($snapmirrored -eq $false)
			{
				$SMstate=Get-NcSnapmirror -zapicall -Destination $relation.DestinationLocation
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
				Invoke-NcSnapmirrorUpdate -zapicall -Destination $relation.DestinationLocation |out-null
				Logwrite "Let's check replication status"
				$snapmirrored = $false
				while ($snapmirrored -eq $false)
				{
					$SMstate=Get-NcSnapmirror -zapicall -Destination $relation.DestinationLocation
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
				$NewSMstate=Get-NcSnapmirror -zapicall -Destination $relation.DestinationLocation
				if ($NewSMstate.NewestSnapshot -ne $monthlysnap.name)
				{
					Logwrite "Monthly Snapshot is unlocked. We can remove it"
					Remove-NcSnapshot -zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $monthlysnap.name -confirm:$false |out-null
				}
			}
			if ($yearly -eq $true)
			{
				Logwrite "Let's clean Yearly Snapshot "
				$NewSMstate=Get-NcSnapmirror -zapicall -Destination $relation.DestinationLocation
				if ($NewSMstate.NewestSnapshot -ne $yearlysnap.name)
				{
					Logwrite "Yearly Snapshot is unlocked. We can remove it"
					Remove-NcSnapshot -zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $yearlysnap.name -confirm:$false |out-null
				}
			}
			Logwrite "Cleaning old weekly snapshots "
			#listing all weekly snapshots 
			$snaps=get-ncsnapshot -zapicall -vserver $relation.sourcevserver -volume $relation.sourcevolume |?{$_.name -match "Weekly" -and $_.Dependency -ne "snapmirror"} |Sort-Object -Property Created -Descending
			if ($snaps.count -gt $maxweeklysnapcount)
			{
				#Select the older snap from the list
				$snaptodelete = $snaps[-1]
				LogWrite "Deleting snapshot : $($snaptodelete.name) created on : $($snaptodelete.created)"
				Remove-NcSnapshot -zapicall -Volume $relation.sourcevolume -VserverContext $relation.sourcevserver -Snapshot $snaptodelete.name -confirm:$false |out-null
			}
		}
	}
	if ($notsunday -eq $true)
	{
		#Just display the SMC Dashboard with lagtime
		$ts =  [timespan]::fromseconds($relation.lagtime)
		$res = "$($ts.hours)H:$($ts.minutes)M:$($ts.seconds)"
		Logwrite "$($relation) -Lag Time- $($res)"
	}
}
