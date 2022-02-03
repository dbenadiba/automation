Param(
	[Parameter(Mandatory=$true)][string]$sharename
	)

$netapppasswordfile = 'na_pwd_do_not_delete'

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

Connect_Filer cluster1

#$cred=Get-Credential -UserName admin -Message "Insert creds for Cluster1"
#$Ctrl = Connect-NcController cluster1 -Credential $cred

#Set the new retention to current time + 5 min
$dt = Get-Date

$Sharedetails=Get-NcCifsShare -ShareName $sharename
$path = "/vol"+$Sharedetails.path

$files=Read-NcDirectory -Path $path -VserverContext $Sharedetails.vserver| ?{$_.type -eq "file" }| ?{$_.empty -ne $false} | ?{$_.size -ne '0'}

foreach ($file in $files.path)
{
	write-host "------- $($file) -----"
	$isfilelocked=Get-NcSnaplockRetentionTime -File $file -VserverContext $Sharedetails.vserver -ErrorAction SilentlyContinue
	if ($isfilelocked)
	{
		#Compare retention dates versus dt
		if ($isfilelocked.RetentionTimeDT -gt $dt)
		{
			write-host "File is still locked can't be removed" -Foregroundcolor Red
			Write-host "Current: $($isfilelocked.RetentionTimeDT)  vs dt: $($dt)"
		}
		else
		{
			write-host "File retention is over! Can be deleted " -Foregroundcolor Green
			Write-host "Current: $($isfilelocked.RetentionTimeDT)  vs dt: $($dt)"
			write-host "delete-item -path $($file)"
		}
	}
	else
	{
		#Set snaplock retention stime to $dt it will lock the file with min retention
		write-host "---> File Not locked" -Foregroundcolor Green
		$ANS=Read-Host -Prompt "Do you want to lock it ?(y/n)"
		if ($ANS -eq "y")
		{
			write-host "Locking file: $($file)"
			Set-NcSnaplockRetentionTime -File $file -RetentionTime $dt -VserverContext $Sharedetails.vserver
		}
		else{
			write-host "not encrypting .."
		}
		
	}
	write-host " "	
}
$folders = Read-NcDirectory -Path $path -VserverContext $Sharedetails.vserver| ?{$_.type -eq "directory" }| ?{$_.name -notlike ".*"}
foreach ($folder in $folders)
{
    $folderpath = $path +"/"+$folder.name
    $files=Read-NcDirectory -Path $folderpath -VserverContext $Sharedetails.vserver| ?{$_.type -eq "file" }| ?{$_.empty -ne $false} | ?{$_.size -ne '0'}

    foreach ($file in $files.path)
    {
        write-host "------- $($file) -----"
        $isfilelocked=Get-NcSnaplockRetentionTime -File $file -VserverContext $Sharedetails.vserver -ErrorAction SilentlyContinue
        if ($isfilelocked)
        {
            #Compare retention dates versus dt
            if ($isfilelocked.RetentionTimeDT -gt $dt)
            {
                write-host "File is still locked can't be removed" -Foregroundcolor Red
                Write-host "Current File Retention : $($isfilelocked.RetentionTimeDT)  vs Current Date: $($dt)"
            }
            else
            {
                write-host "File retention is over! Can be deleted " -Foregroundcolor Green
                Write-host "Current File Retention : $($isfilelocked.RetentionTimeDT)  vs Current Date: $($dt)"
                write-host "delete-item -path $($file)"
            }
        }
        else
        {
            #Set snaplock retention stime to $dt it will lock the file with min retention
            write-host "---> File Not locked" -Foregroundcolor Green
			$ANS=Read-Host -Prompt "Do you want to lock it ?(y/n)"
		if ($ANS -eq "y")
		{
			write-host "Locking file: $($file)"
			Set-NcSnaplockRetentionTime -File $file -RetentionTime $dt -VserverContext $Sharedetails.vserver
		}
		else{
			write-host "not encrypting .."
		}
        }
        write-host " "	

    }
}
