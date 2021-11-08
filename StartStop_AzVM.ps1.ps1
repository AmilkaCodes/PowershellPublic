

param(
    [parameter(Mandatory = $false)]
    [string]$SubscriptionId = "SampleText",
    [parameter(Mandatory = $false)]
    [string]$TagName = "StopStartSchedule",
    [parameter(Mandatory = $false)]
    [string]$TimeZone = "UTC"
)

# the runbook is based on a unique tag applied on target VMs. The value of this tag must match the following expression : Weekdays=07:00–22:00 / Weekends=09:00–20:00. Values for weekdays and weekends can be :
#0 : VM should be stopped all involved days
#1 : VM should be started all involved days
#01:00–22:00 : VM should be started between 01:00 and 22:00 (and stopped otherwise)


# Connect to Azure using System Assigned Managed Identity

connect-azaccount -identity
Write-Output "Successfully logged into Azure subscription using Az cmdlets..."

# Set subscription as context
try {
    Set-AzContext -Subscription $SubscriptionId
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

# Check if TimeZone parameter is OK
if ($TimeZone -match 'UTC' -or (Get-TimeZone -ListAvailable | find $TimeZone)) {
    Write-Output "Specified Time Zone $TimeZone is valid"
}
else {
    Write-Output "Specified Time Zone $TimeZone is invalid, please check the value. Exiting runbook."
    exit
}

### Second Step : Get all VM with the tag

$VMs = Get-AzResource -ResourceType "Microsoft.Compute/VirtualMachines" -TagName $TagName
Write-Output "Found $($VMs.Count) VM with tag $TagName defined"

# Exit now if no VM is detected
if (!$VMs) {
    Write-Output "No VM with state schedule management tag ($TagName) have been found in the provided scope (subId : $SubscriptionID )"
    exit
}

### Third Step : Manage status for each VM
$VMActionList = @()
foreach ($VM in $VMs) {
    Write-Output "Processing $($VM.Name) virtual machine. It will be started or stopped if according tag value is matched"
    # Extract values from tag
    # Tag Sample : StopStartSchedule = Weekdays=07:00-20:00 / Weekends=0
    $ScheduleTagValue = ($VM.Tags).$TagName
    if ($ScheduleTagValue -like '*/*') {
        $WeekdaysUptime = (($ScheduleTagValue.Split('/')[0]).Split('=')[1]).Trim(' ')
        $WeekendsUptime = (($ScheduleTagValue.Split('/')[1]).Split('=')[1]).Trim(' ')
    }
    else {
        Write-Output "Stop and Start tag $ScheduleTagValue does not match expected value (i.e. Weekdays=07:00-20:00 / Weekends=0), exiting runbook."
        exit
    }

    # Check if weekdays value is ok / This should be reworked because its quite an ugly check
    $TimeTagRegex = '^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]-([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]'
    if ($WeekdaysUptime -match $TimeTagRegex -or $WeekdaysUptime -eq '0' -or $WeekdaysUptime -eq '1') {
        Write-Output "Weekdays uptime $WeekdaysUptime match expected value (i.e. Weekdays=07:00-20:00 or Weekdays=1), moving on."
    }
    else {
        Write-Output "Weekdays uptime $WeekdaysUptime does not match expected value (i.e. Weekdays=07:00-20:00 or Weekdays=1), exiting runbook."
        exit
    }
    # Same for weekends
    if ($WeekendsUptime -match $TimeTagRegex -or $WeekendsUptime -eq '0' -or $WeekendsUptime -eq '1') {
        Write-Output "Weekends uptime $WeekendsUptime match expected value (i.e. Weekends=07:00-20:00 or Weekends=1), moving on."
    }
    else {
        Write-Output "Weekends uptime $WeekendsUptime does not match expected value (i.e. Weekends=07:00-20:00 or Weekends=1), exiting runbook."
        exit
    }

    # Adjust time based on the timezone passed as argument (default UTC)
    # Beware, no control on the value passed as $TimeZone!
    $CurrentTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::Now, $TimeZone)

    # Define schedule time to use depending on weekday / weekend
    If ($CurrentTime.DayOfWeek -like 'S*') {
        $ScheduledTime = $WeekendsUptime
    }
    else {
        $ScheduledTime = $WeekdaysUptime
    }

    # Extract start and stop time from the tag (looking like that 7:00AM-08:00PM, or 0 if VM should be stopped / 1 VM should be started)
    if ($ScheduledTime -eq '0') {
        $VMAction = "Stop"
    }
    elseif ($ScheduledTime -eq '1') {
        $VMAction = "Start"
    }
    else {
        $ScheduledTime = $ScheduledTime.Split('-')
        $ScheduledStartHour = $ScheduledTime[0].split(':')[0]
        $ScheduledStartMinute = $ScheduledTime[0].split(':')[1]
        $ScheduledStopHour = $ScheduledTime[1].split(':')[0]
        $ScheduledStopMinute = $ScheduledTime[1].split(':')[1]
                
        $ScheduledStartTime = Get-Date -Hour $ScheduledStartHour -Minute $ScheduledStartMinute -Second 0
        $ScheduledStopTime = Get-Date -Hour $ScheduledStopHour -Minute $ScheduledStopMinute -Second 0
    
        # Determine if an action should be done on the VM
        If (($CurrentTime -gt $ScheduledStartTime) -and ($CurrentTime -lt $ScheduledStopTime)) {
            #Current time is within the interval
            Write-Output "VM $($VM.Name) should be running now"
            $VMAction = "Start"
        }
        else {
            #Current time is outside of the operational interval
            Write-Output "VM $($VM.Name) should be stopped now"
            $VMAction = "Stop"
        }
    }

    # Get current power state for a VM
    $VM = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
    $VMCurrentState = ($VM.Statuses | Where-Object Code -like "*PowerState*").DisplayStatus
        
    # Start or Stop the VM according to the VM action. If the action matches the current state, do nothing.
    # States are checked against 'healthy' statuses to avoid sending a Start request to a Stopping VM
    if ($VMAction -eq "Start" -and ($VMCurrentState -like "*stopped*" -or $VMCurrentState -like "*deallocated")) {
        Write-Output "Starting VM $($VM.Name)"
        Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name
    }
    elseif ($VMAction -eq "Stop" -and $VMCurrentState -like "*running*") {
        Write-Output "Stopping VM $($VM.Name)"
        Stop-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Force
    }
    else { 
        Write-Output "VM $($VM.Name) already in target state ($VMCurrentState)"
    }
    
    # Build a table for results
    $VMInfo = "" | select VM, Action
    $VMInfo.VM = $VM.Name
    $VMInfo.Action = $VMAction
    $VMActionList += $VMInfo
}

Write-Output $VMActionList
Write-Output "Runbook completed."
