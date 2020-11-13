# PowerShell script to create a source volume snapshot and then clone the source volume
# N times from that snapshot. The names of the resulting cloned volumes will follow
# the format "{source_vol_name}_cloneN", and will be mounted into the SVM namespace
# as "/{source_vol_name}_cloneN".

##### Editable script control variables #####
#test2
$cluster = 'cluster1.demo.netapp.com'  # Target cluster FQDN
$volname = "pri_svm_01_iscsiwin_01"              # Name of source volume
$svmname = "pri_svm_01"             # Name of SVM hosting source volume
$snapshot = "Clone Source"     # Name of snapshot to create on source volume
$numclones = 10                # Number of volume clones to create
$maxtries = 10                 # Maxmimum number of attempts to query job status before timeout

# response type and base64-encoded credentials data for -header parameter 
$header = @{"accept" = "application/hal+json"; "authorization" = "Basic YWRtaW46TmV0YXBwMSE=" }

################################################################################################
########## under normal conditions, no editing should be necessary beyond this point. ##########
################################################################################################

$clusterurl = "https://$cluster" # base URL for ONTAP REST API calls to the specified cluster

##### Get the uuid of the source volume.

# Construct the URI for the method
$methodtype = "GET"
$methodpath = "/api/storage/volumes"
$parameters = "?name=" + $volname + "&fields=*&return_records=true&return_timeout=15"
$uri = $clusterurl + $methodpath + $parameters
# Invoke the method to get the volume uuid
try {
  $response = Invoke-RestMethod -header $header -method $methodtype -uri $uri
} catch {
  $apierror = $_ | ConvertFrom-json
  throw "method " + $methodtype + " " + $methodpath + " error: target = " + $apierror.error.target + ", " + $apierror.error.message
}
$voluuid = $response.records.uuid  # uuid of source volume

#configure the volume to be autogrow off
$methodtype = "PATCH"
$methodpath = "/api/storage/volumes"
$parameters = "?name=" + $volname + "&fields=*&return_records=true&return_timeout=15"
$uri = $clusterurl + $methodpath + $parameters

$payload = @{
  'autosize' = @{'mode' = "off"
             };
	'space' = @{'size' = "1700m"}
}

 $payloadJSON = $payload | ConvertTo-json
# Invoke the method to create the snapshot
try {
  $response = Invoke-RestMethod -header $header -method $methodtype -uri $uri -Body $payloadJSON
} catch {
  # If API call generates an exception then abort the script.
  $apierror = $_ | ConvertFrom-json
  throw "method " + $methodtype + " " + $methodpath + " error: target = " + $apierror.error.target + ", " + $apierror.error.message
}
$jobuuid = $response.job.uuid   # uuid of create vol modify job

