param(
    [Parameter()]
    [ValidateSet('ONE_DAY','ONE_WEEK','THIRTY_DAYS')]
    [string]$timestamp,
	[Parameter()]
	[ValidateSet('Management','Reporting')]
	[string]$AuditType
)
#variables
$headers = @{
    "accept" = "application/json;charset=UTF-8"
    "X-CloudInsights-ApiKey" = "eyJraWQiOiI5OTk5IiwidHlwIjoiSldUIiwiYWxnIjoiSFMzODQifQ.eyJjcmVhdG9yTG9naW4iOiJzYW1scHxOZXRBcHBTQU1MfGRiZW5hZGliIiwiZGlzcGxheU5hbWUiOiJEQkVfVE9LRU4gKG9uIGJlaGFsZiBvZiBEYXZpZCBCZW5hZGliYSkiLCJyb2xlcyI6W10sImlzcyI6Im9jaSIsIm5hbWUiOiJEQkVfVE9LRU4iLCJhcGkiOiJ0cnVlIiwiZXhwIjoxNzI3NDM4MDE4LCJsb2dpbiI6IjZlY2RjM2RmLTJjYmUtNGZhZS1iYmYwLTljMzg3YmQyYzEzZiIsImlhdCI6MTY5NTkwMjAyMCwidGVuYW50IjoiMGQwMDkyNWUtYWJkZC00MzA5LWI5MDYtOWM1MGI1NjBkODVmIn0.DKjmZf0djm5Vpx0UGOWwTOE_7GoBd2yZuZUDU20GI8M0XHV3494AkaW6uzjEvm9W"
}

#main
#Query for all declared users in the tenant
$response = Invoke-RestMethod -Uri "https://vk6769.c01-eu-1.cloudinsights.netapp.com/rest/v1/users" -Headers $headers
$allusersemail = $response.users.email 

#Query to get audit from connexion to CI
$response = Invoke-RestMethod -Uri "https://vk6769.c01-eu-1.cloudinsights.netapp.com/rest/v1/audit/query?category=$($AuditType)" `
    -Method Post `
    -Headers $headers `
    -ContentType "application/json" `
    -Body "{`n  `"expression`": `"category:$($AuditType)`",`n  `"offset`": 0, `n  `"limit`": 9999,`n  `"sort`": `"-timestamp`",`n  `"timeRange`": `"$($timestamp)`" `n}"
$connex=$response.results.userReference

#randering
foreach ($user in $allusersemail)
{
	if ($connex.email -match $user)
	{
		#user found
		$count=($connex.email -match $user).count
		if ($timestamp -eq "ONE_DAY")
		{
			write-host "$($user) was connected $($count) times during the past 1 days" -foregroundcolor GREEN
		}
		if ($timestamp -eq "ONE_WEEK")
		{
			write-host "$($user) was connected $($count) times during the past week" -foregroundcolor GREEN
		}
		if ($timestamp -eq "THIRTY_DAYS")
		{
			write-host "$($user) was connected $($count) times during the past 30 days" -foregroundcolor GREEN
		}
		
	}
	else
	{
		#user did not connect
		if ($timestamp -eq "ONE_DAY")
		{
			write-host "$($user) was not connected during the past 1 days" -foregroundcolor RED
		}
		if ($timestamp -eq "ONE_WEEK")
		{
			write-host "$($user) was not connected during the past week" -foregroundcolor RED
		}
		if ($timestamp -eq "THIRTY_DAYS")
		{
			write-host "$($user) was not connected during the past 30 days" -foregroundcolor RED
		}
	}
}

