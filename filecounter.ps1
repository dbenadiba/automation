Param(
	[Parameter(Mandatory=$true)][string]$Cluster,
	[Parameter(Mandatory=$true)][string]$SVM
    )
<#
## Since 9.13.1 You can tag ressources like volumes
#get records for a specific tag : application:oracleDB
curl -k -X GET "https://cluster1.demo.netapp.com/api/resource-tags/application%3AoracleDB/resources?fields=**" -H  "accept: application/json" -H  "authorization: Basic YWRtaW46TmV0YXBwMSE="
Get All tags available
curl -k -X GET "https://cluster1.demo.netapp.com/api/resource-tags?fields=**" -H  "accept: application/json" -H  "authorization: Basic YWRtaW46TmV0YXBwMSE="
#Get Volume name from a vol uuid 
 curl -k -X GET "https://cluster1.demo.netapp.com/api/storage/volumes/e993c101-7c7d-11ee-ae8d-00505681d406?fields=name" -H  "accept: application/json" -H  "authorization: Basic YWRtaW46TmV0YXBwMSE="
#Add a tag to a ressource
curl -X POST "https://cluster1.demo.netapp.com/api/resource-tags/fromapi%3Avaluefromapi/resources?return_records=false" -H  "accept: application/json" -H  "authorization: Basic YWRtaW46TmV0YXBwMSE=" -H  "Content-Type: application/json" -d "{  \"href\": \"/api/storage/volumes/e993c101-7c7d-11ee-ae8d-00505681d406\"}"
#List all files/folder under 500 B
curl -siku admin:Netapp1! --request GET "https://cluster1/api/storage/volumes/a2d55d6b-87f2-11ec-88b2-005056b77e96/files/Top_Dir_1%2FSub_Dir_11?size=<500&fields=*"
#Write a file in a volume
curl -siku admin:Netapp1! -X POST "https://cluster1/api/storage/volumes/83f3047d-837e-11ec-8c9d-005056b0d995/files/aNewFile" -H "Content-Type: multipart/form-data" --form "file=the data to be written to the new file"
#Read a File from REST Api call
curl -siku admin:Netapp1! --request GET "https://cluster1/api/storage/volumes/83f3047d-837e-11ec-8c9d-005056b0d995/files/src_file?byte_offset=0&length=100" -H "Accept: multipart/form-data"
curl -siku admin:Netapp1! --request GET "https://cluster1/api/storage/volumes/4438aed6-8840-11ec-8e71-005056b775ef/files/.anti_ransomware_analytics_log%2extn.txt?byte_offset=0&length=100" -H "Accept: multipart/form-data"
"https://cluster1/api/storage/volumes/83f3047d-837e-11ec-8c9d-005056b0d995/files/Top_Dir_1%2FSub_Dir_11?fields=*&max_records=10000"
Usage: ana.ps1 -Cluster cluster1 -SVM prod
#>

#Creds
$Logfilebase = "C:\LOD\File_Analitycs_SVM_log"
$maxlogfiles = 5
$maxlogfilesize = 50KB

$WorkingDir="C:\LOD\"
$netappusername = 'admin'
$netapppasswordfile = '_na_pwd_do_not_delete'
$passwordfile = "$($PSScriptRoot)\$($netapppasswordfile)"

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

function AnalyticsInRoot ($uri,$vol)
{
	$result=Invoke-RestMethod -Method GET -Uri $uri -Credential $cred
	if ($result._links.next)
	{
		#there is more than 10000 items ;)
		$count=0
		$filecount=0
		$more=$true
		while($more -eq $true)
		{
			
			write-host "At the root of this volume: $($vol) there is $(($result.records).count) files" -foregroundcolor green
			#$outfile=$vol+"_"+$count+".json"
			#$result.records|out-file $outfile
			$uri= "https://"+$Cluster+$result._links.next.href
			$result=Invoke-RestMethod -Method GET -Uri $uri -Credential $cred
			$count++
			#$count
			if (!$result._links.next)
			{
				#fin du game
				$more=$false
				$filecount = $filecount + ($result.records).count
				write-host ">> The directory $($dirpath) in volume $($vol) has $($filecount) files" -foregroundcolor yellow
			}
		}
	}
	else
	{
		write-host "At the root of this volume: $($vol) there is $(($result.records).count) files" -foregroundcolor green
		#$outfile=$vol+"_"+".json"
		#$result.records|out-file $outfile
	}
}

function AnalyticsInADir ($uri,$dir,$vol)
{
	$result=Invoke-RestMethod -Method GET -Uri $uri -Credential $cred
	if ($result._links.next)
	{
		#there is more than 10000 items ;)
		$count=0
		$filecount=0
		$more=$true
		while($more -eq $true)
		{
			$dirpath=$result.records.path |select -Unique
			$filecount = $filecount + ($result.records).count
			#$dirpath=$dirpath.replace('/','__')
			#$outfile=$vol+"_"+$dirpath+"_"+$count+".json"
			#$result.records|out-file $outfile
			$uri= "https://"+$Cluster+$result._links.next.href
			$result=Invoke-RestMethod -Method GET -Uri $uri -Credential $cred
			$count++
			if (!$result._links.next)
			{
				#fin du game
				$more=$false
				$filecount = $filecount + ($result.records).count
				write-host ">> The directory $($dirpath) in volume $($vol) has $($filecount) files" -foregroundcolor yellow
			}
		}
	}
	else
	{
		$dirpath=$result.records.path |select -Unique
		#$dirpath=$dirpath.replace('/','__')
		#$outfile=$vol+"_"+$dirpath+"_"+".json"
	
		#let's check if there is directories
		#$result.records|out-file $outfile
		write-host ">> The directory $($dirpath) in volume $($vol) has $(($result.records).count) files" -foregroundcolor yellow
		$dirs=$result.records|?{$_.type -match "dir" -and $_.name -ne "." -and $_.name -ne ".." -and $_.name -ne ".snapshot" -and $_.name -ne "." -and $_.name -ne ".anti_ransomware_analytics_log"}
		
		if ($dirs)
		{
			#lets run it again with this new path
			foreach ($dir in $dirs)
			{

				$newuri="https://"+$Cluster+$dir._links.metadata.href
				$newuri=$newuri.replace('return_metadata=true','fields=*')
				#$newuri
				AnalyticsInADir -uri $newuri -dir $dir.name -vol $vol
			}
			
		}
		
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


#Main

#Get Some info first (Volume UUID, SVM UUID, Snapshots)
#$UriVolume = "https://"+$Cluster+"/api/storage/volumes?svm.name=$($SVM)&name=$($Volume)&fields=uuid,state"
#$Volinfo=Invoke-RestMethod -Method GET -Uri $UriVolume -headers $hdrs -credential $cred
$UriSVM = "https://"+$Cluster+"/api/svm/svms?name=$($SVM)&return_records=true&return_timeout=15"
$SVMInfo=Invoke-RestMethod -Method GET -Uri $UriSVM -headers $hdrs -credential $cred
#$UriBaseFolder="https://$($Cluster)/api/storage/volumes/$($Volinfo.records.uuid)/files/?type=directory&fields=*"
#$BaseFolder=Invoke-RestMethod -Method GET -Uri $UriBaseFolder -headers $hdrs -credential $cred
$UriVolumes = "https://"+$Cluster+"/api/storage/volumes?svm.name=$($SVM)&fields=name,uuid,state,is_svm_root"
$Volsinfo=Invoke-RestMethod -Method GET -Uri $UriVolumes -headers $hdrs -credential $cred
foreach ($vol in $Volsinfo.records)
{
	if($vol.is_svm_root)
	{
		Logwrite "Skipping Root Volume" 
	}
	else
	{
		LogWrite "++++++Working on volume $($vol.name)+++++++"
		$UriVolume = "https://"+$Cluster+"/api/storage/volumes?svm.name=$($SVM)&name=$($vol.name)&fields=name,uuid,state"
		$Volinfo=Invoke-RestMethod -Method GET -Uri $UriVolume -headers $hdrs -credential $cred
		$UriBaseFolder="https://$($Cluster)/api/storage/volumes/$($Volinfo.records.uuid)/files/?type=directory&fields=*"
		$BaseFolder=Invoke-RestMethod -Method GET -Uri $UriBaseFolder -headers $hdrs -credential $cred
		#getfolder 
		foreach($dir in $BaseFolder.records)
		{
			if ($dir.name -ne "." -and $dir.name -ne ".." -and $dir.name -ne ".snapshot" )
			{
				#
				write-host "Working on folder $($dir.name)"
				$newuri="https://$($Cluster)/api/storage/volumes/$($Volinfo.records.uuid)/files/"+$dir.name+"?fields=*&max_records=10000"
				AnalyticsInADir -uri $newuri -dir $dir.name -vol $vol.name
			}
		}
		#get files in the root 
		$UriRootFolder="https://$($Cluster)/api/storage/volumes/$($Volinfo.records.uuid)/files/?fields=*&max_records=10000"
		AnalyticsInRoot -uri $UriRootFolder  -vol $vol.name
	}
	
}
