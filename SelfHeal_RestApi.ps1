function GetEvent{
    param(
        [string[]]$arguments
    )
    $validArguments = "-eventID","-eventName","-eventSeverity","-eventSourceID","-eventSourceName","-eventSourceType","-eventState","-eventArgs"
    $event = "" | select id,name,severity,sourceId,sourceName,sourceType,state,args
    $argname = ""
    $argvalue = @()
    foreach($arg in $arguments){
        if($arg -in $validArguments){
            if($argvalue){
                $value = $argvalue -join " "
                $event."$argname"=$value
            }
            $argname = ([string]$arg).TrimStart("-event")
            write-verbose "new argument $argname"
            $argvalue = @()
        }else{
            $argvalue+=$arg
        }
    }
    if($argvalue){
        $value = $argvalue -join " "
        $event."$argname"=$value
    }
    $event
}

function MySQL {
    Param(
        [Parameter(Mandatory = $true,ParameterSetName = '',ValueFromPipeline = $true)]
        [string]$Query
    )

    
	$MySQLAdminUserName = "dbuser"
	$MySQLAdminPassword = "Netapp1!"
	$MySQLDatabase = 'ocum_report'
	$MySQLHost = "192.168.0.5"
	$ConnectionString = "server=" + $MySQLHost + ";port=3306;Integrated Security=False;uid=" + $MySQLAdminUserName + ";pwd=" + $MySQLAdminPassword + ";database="+$MySQLDatabase
	 
    Try {
        [void][System.Reflection.Assembly]::LoadFrom("C:\Program Files (x86)\MySQL\MySQL Connector Net 8.0.21\Assemblies\v4.5.2\MySql.Data.dll")
        $Connection = New-Object MySql.Data.MySqlClient.MySqlConnection
        $Connection.ConnectionString = $ConnectionString
        $Connection.Open()

        $Command = New-Object MySql.Data.MySqlClient.MySqlCommand($Query, $Connection)
        $DataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($Command)
        $DataSet = New-Object System.Data.DataSet
        $RecordCount = $dataAdapter.Fill($dataSet, "data")
        $DataSet.Tables[0]
    }

    Finally {
        $Connection.Close()
    }
}

#Main

# Parse Event From Arguments (join chopped pieces)
# Testing
#$args |out-file c:\script\ttt.txt
$ocum_event = GetEvent -arguments $args

# Get Event Information
$event_name = $ocum_event.name
$event_state = $ocum_event.state
$sourceID = $ocum_event.SourceID

# Ignore all non-new events
if ($event_state.tolower() -ine "new"){
    exit
}
else
{
	$sql_query = @"
	SELECT
	   volume.id AS 'Vol_ID',
	   volume.name AS 'Volume',
	   volume.sizeUsed as 'VolumeSize',
	   cluster.name AS 'Cluster',
	   svm.name AS 'Svm'
	FROM
	   volume,
	   cluster,
	   svm
	WHERE
	   volume.id=$($ocum_event.SourceID)
	   AND cluster.id=volume.clusterId
	   AND svm.id=volume.svmId
"@

		
	#Getting volume details
	$ocum_vol= MySQL -query $sql_query
	$cluster_name = $ocum_vol.Cluster
	$svm_name = $ocum_vol.Svm
	$volume_name = $ocum_vol.Volume 
	$volume_size = [long]($ocum_vol.VolumeSize/1mb)
	
	#
	#### Ignore cert validation with ontap
	if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type)
	{
	$certCallback = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            if(ServicePointManager.ServerCertificateValidationCallback ==null)
            {
                ServicePointManager.ServerCertificateValidationCallback += 
                    delegate
                    (
                        Object obj, 
                        X509Certificate certificate, 
                        X509Chain chain, 
                        SslPolicyErrors errors
                    )
                    {
                        return true;
                    };
            }
        }
    }
"@
    Add-Type $certCallback
	}

[ServerCertificateValidationCallback]::Ignore()
	#
	
	#Connection to Cluster using REST Api
	# response type and base64-encoded credentials data for -header parameter 
	$header = @{"accept" = "application/hal+json"; "authorization" = "Basic YWRtaW46TmV0YXBwMSE=" }
	$clusterurl = "https://$cluster_name" # base URL for ONTAP REST API calls to the specified cluster
		
	##### Get the uuid of the source volume.
	# Construct the URI for the method
	$methodtype = "GET"
	$methodpath = "/api/storage/volumes"
	$parameters = "?name=" + $volume_name + "&fields=*&return_records=true&return_timeout=15"
	$uri = $clusterurl + $methodpath + $parameters
	# Invoke the method to get the volume uuid
	try {
	  $response = Invoke-RestMethod -header $header -method $methodtype -uri $uri
	} catch {
	  $apierror = $_ | ConvertFrom-json
	  throw "method " + $methodtype + " " + $methodpath + " error: target = " + $apierror.error.target + ", " + $apierror.error.message
	}
	$voluuid = $response.records.uuid  # uuid of source volume
	$aggr_name =  $response.records.aggregates.name
	$totalsizeingb = $response.records.space.size/1gb
	$usedsizeingb= $response.records.space.used /1gb
	$percentused = ($usedsizeingb/$totalsizeingb)*100
	#How much space do I need to get under 85%
	$newtotalnizeingb=($usedsizeingb * 100)/85
	$newtotalnizeingb= [MATH]::Ceiling([decimal]($newtotalnizeingb)) 
	$additionalspace = $newtotalnizeingb - $totalsizeingb 
	$newtotalnizeingb=$newtotalnizeingb.tostring()+"g"
	
	# Search if aggregate can contain new size
	#Get available capacity on current aggregate
	$methodtype = "GET"
	$methodpath = "/api/storage/aggregates"
	$parameters = "?name="+$aggr_name+"&fields=*&return_records=true&return_timeout=15"
	$uri = $clusterurl + $methodpath + $parameters
	# Invoke the method to get the volume details
	try {
	  $responseaggr = Invoke-RestMethod -header $header -method $methodtype -uri $uri
	} catch {
	  $apierror = $_ | ConvertFrom-json
	  throw "method " + $methodtype + " " + $methodpath + " error: target = " + $apierror.error.target + ", " + $apierror.error.message
	}
	$aggrtotalsize = $responseaggr.records.space.block_storage.size / 1gb
	$aggravailspace = $responseaggr.records.space.block_storage.available / 1gb
	$aggrusablespace = ($aggrtotalsize *85 )/100
	#Lets check if it is less than additional capacity
	$AvailSizeOfTheAggrAfterResize = $aggravailspace - $additionalspace
	
	if ($AvailSizeOfTheAggrAfterResize -gt $aggrusablespace )
	{
		#Oki ther is enough Room to perform the vol resize
		#ResizeVol
		$methodtype = "PATCH"
		$methodpath = "/api/storage/volumes"
		$parameters = "?name=" + $volume_name + "&fields=*&return_records=true&return_timeout=15"
		$uri = $clusterurl + $methodpath + $parameters

		$payload = @{
			'space' = @{'size' = $newtotalnizeingb}
		}
		$payloadJSON = $payload | ConvertTo-json
		# Invoke the method to create the snapshot
		$responseaddcapa = Invoke-RestMethod -header $header -method $methodtype -uri $uri -Body $payloadJSON

	}
	else
	{
		#there is not enough space Need to write a function that will serach suitable aggregate and run a vol move
		$notenogh = "AggrUsableSpace With 85%"+$aggrusablespace +"   AvailSizeOfTheAggrAfterResize:"+$AvailSizeOfTheAggrAfterResize +"::::: aggravailspace:" + $aggravailspace + ":::::: additionalspace" + $additionalspace
	}
	#
}

