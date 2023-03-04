<#
.SYNOPSIS
Save and clear event logs in Windows computers
.DESCRIPTION
Saves the selected log (Security, Application, System) to a file on disk, then clears the log.
Optionally changes the crashonauditfail registry value to 1.
Optionally reboots the computer.
.PARAMETER ComputerList
A new-line separated text file containing the hostnames or IP addresses of all the computers to act upon. The default parameter value is "ComputerList.txt".
.PARAMETER ComputerName
To run the script on a single computer without using a computerlist.txt file
.PARAMETER LogFile
The path to which the script will save script output logs. The default parameter value is "Clear-EventLog-<currentdatetime>UTC-Log.txt".
.PARAMETER LogType
The Windows log to act upon. System, Security, or Application are the only valid choices. The default parameter value is "Security".
.PARAMETER EventLogBackupPath
The location on the target computer where the event log will be saved. The default parameter value is C:\EventLogs\.
.PARAMETER NoCrashOnAudit
To disable resetting the crashonaudit registry value, use this switch parameter.
.PARAMETER reboot
To reboot the target computers, use the reboot switch
.INPUTS
Credentials of an administrator of the target computers.
.OUTPUTS
Log file stored in $LogFile\<CurrentDateTime>-Log.txt
Saved event log file on each computer.
Cleared event log
.NOTES
Version:        1.0
Author:         Stephen Harper
Company:        Alpha Omega Integration
Client:         Department of State A/EX/ITS
Creation Date:  2/27/2023
Purpose/Change: Initial script development
.EXAMPLE
Clear-EventLog.ps1 -reboot
Run the script with the default settings, and reboot each computer. 

Default settings include:

    * Saving and clearing the Security log
    * Resetting the crashonauditfail registry value
    * Using the computerlist.txt file in the current directory
    * Using the Q:, D:, and C: drives with the default paths for event logs.
    * Using the current directory for the script log file.

.EXAMPLE
Clear-EventLog.ps1 -ComputerList computers.txt
Specify a custom computer list file instead of computerlist.txt.

.EXAMPLE
Clear-EventLog.ps1 -LogType Application -NoCrashOnAudit
Save and clear the Application log, and do not change the crashonaudit registry value.

It is good practice to only reboot the computers when clearing the Security log AND resetting the registry value.

.EXAMPLE
Clear-EventLog.ps1 -quiet
Run the script with no console output.

.EXAMPLE
Clear-EventLog.ps1 -ComputerList computers.txt -LogFile c:\logs -LogType System
Specify a custom computer list, custom script log file directory, and select the System log.

.EXAMPLE
Clear-EventLog.ps1 -EventLogBackupPath C:\MyBackups\
Specify saving the event logs in the C:\MyBackups\ directory on each computer instead of the script's default paths.

.EXAMPLE
Clear-EventLog.ps1 -ComputerName Server2 -reboot
Run against a single computer and then reboot.

Use caution when using the -reboot option. The script will not prompt the administrator to confirm the reboot. 
If the current computer is not last in the list in the computerlist.txt file, the reboot will happen before
the rest of the computers have been updated. The script will not resume upon completion of the reboot.

.NOTES
This script requires administrative access to remote computers. 
This script requires PowerShell remoting to be enabled on remote computers.
This script was developed to address a concern with the Security log on servers filling up to quickly causing the server to halt due to the security settings.

#>

#-----------------------------------------------------Parameters-----------------------------------------------------#

 [CmdletBinding(DefaultParameterSetName = 'File')]
 Param (   
    [Parameter(Mandatory = $false, 
        HelpMessage = "The path to the text file containing the names of the computers this script should work with. Default value is ComputerList.txt in current directory.", 
        ParameterSetName="File",
        Position=0)]
    [String]$ComputerList = "ComputerList.txt",

    [Parameter(Mandatory = $true,
        HelpMessage = "The computer name on which to run the script.",
        ParameterSetName="Computer",
        Position=0)]
    [String]$ComputerName,

    [Parameter(Mandatory = $false, 
        HelpMessage = "The directory to store script log files in. Default is <CurrentDateTime>-Log.txt in current directory.")
        ]
    [String]$LogFile = "Clear-EventLog-" + [DateTime]::UtcNow.ToString("yyMMddHHmmssUTC") + "-Log.txt",
    
    [Parameter(Mandatory = $false, 
        HelpMessage = "The server logs you would like to save and clear. Default is Security.")]
    [ValidateSet("Security", "Application", "System")]
    [String]$LogType = "Security",

    [Parameter(Mandatory = $false, 
        HelpMessage = "The location on the target computer where the event logs will be saved.")]
    [String]$EventLogBackupPath = "unset",

    [Parameter(Mandatory=$False,
        HelpMessage = "Use this option to reboot the target computer")]
    [Switch]$Reboot,
    
    [Parameter(Mandatory=$False,
        HelpMessage = "To disable resetting the crashonaudit registry value, use this switch.")]
    [Switch]$NoCrashOnAudit,

    [Parameter(Mandatory=$False,
        HelpMessage = "To disable script output to the screen, use the -quiet switch.")]
    [Switch]$Quiet


)

#-----------------------------------------------------Functions-----------------------------------------------------#
# Just a basic logging function
function write-log([string] $content) {
    if(!($Quiet.IsPresent)){ write-host $content }
    add-content -value $content -Path $LogFile
}

# There is no native "right" method of strings in PS. So, here's one. 
Function Get-RightSubstring {
   [CmdletBinding()]
 
   Param (
      [Parameter(Position=0, Mandatory=$True,HelpMessage="Enter a string of text")]
      [String]$text,
      [Parameter(Position=1, Mandatory=$True)]
      [Int]$Length
   )
    $startchar = [math]::min($text.length - $Length,$text.length)
    $startchar = [math]::max(0, $startchar)
    $right = $text.SubString($startchar ,[math]::min($text.length, $Length))
    $right
}

# The bulk of the script work is here.
function Start-LogCleanupOnComputer ([String]$Computer, [String]$LogType, [String]$LogExportPath) {
    write-log("Now executing on $Computer")
    write-log("Using values:")
    write-log("`tComputer: $Computer")
    write-log("`tLogType: $LogType")
    write-log("`tLogExportPath: $LogExportPath`n")

    # We need to know what drives the server has in it. If it has a Q drive, we'll use that. If it doesn't have a Q drive, but it does have a D drive, we'll use that. Otherwise, we'll use the C: drive.
    $hasQdrive = $false 
    $hasDdrive = $false
    $drives = Invoke-Command -ComputerName $Computer -ScriptBlock { Get-PSDrive -PSProvider FileSystem | Select-Object Name }
    write-log("Found drives on $Computer`:")
    foreach($drive in $drives.Name){
        write-log("`t$drive")
        switch ($drive){
            'Q' { $hasQdrive = $true }
            'D' { $hasDdrive = $true }
        }
    }
        
    # If the user did not supply a path to save log files when running the script, then we'll figure out where to put them. 
    if($LogExportPath -eq "unset"){
        if($hasQdrive -eq $true){
            $LogExportPath="Q:\Windows\System32\winevt\logs\"
        }
        elseif($hasDdrive -eq $true){
            $LogExportPath="D:\Windows\System32\winevt\logs\"
        }
        else{
            $LogExportPath="C:\EventLogs\"
        }
    }
       
    if ((Get-RightSubstring $LogExportPath 1) -ne '\'){
        $LogExportPath = $LogExportPath + "\"
    }
    
    write-log("`nLogExportPath is set to $LogExportPath")
    # If the directory to save the event log doesn't exist, we need to create it.
    
    if (!(Invoke-Command -ComputerName $Computer -ScriptBlock { Test-Path "$Using:LogExportPath" })){
        Invoke-Command -ComputerName $Computer -ScriptBlock { mkdir $Using:LogExportPath }
    }    

    # Get the current date and time in UTC timezone with the Year Month Day Hour Minute Second format
    $now = [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss")
    # Set up the save filename
    $EventLogSaveFile = "$LogType-" + $now + "_UTC.evtx"
    write-log("EventLogSaveFile name is $EventLogSaveFile")
    # Full file name with path
    $EventLogSavePath = $LogExportPath + $EventLogSaveFile 
    write-log("EventLogSavePath is $EventLogSavePath`n")
    
    # Get the log using WMI
    $log = Get-WmiObject -ComputerName $Computer -Class Win32_NTEventLogFile | Where-Object {$_.LogfileName -eq $LogType}

    # Clear the log, saving it first, using the ClearEventLog method
    $logClearStatus = $($log.ClearEventLog($EventLogSavePath)).ReturnValue

    # Log the result of clearing the event log
    switch($logClearStatus){
        0 {
            write-log ("The eventlog was successfully saved and cleared on $Computer.")
        }

        8 {
            write-log("The eventlog was not successfully saved and cleared on $Computer because of a missing privilege.")
        }
        
        21 {
            write-log("Error: Invalid Parameter. Saving and clearing event log on $Computer failed.")
        }
    }

    # Reset the registry value
    if(!($NoCrashOnAudit.IsPresent)){
        write-log("`nSetting HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\crashonauditfail to 1")
        Invoke-Command -ComputerName $Computer -ScriptBlock { Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\Lsa -Name crashonauditfail -Value 1 -Force }
        write-log("Registry value `"crashonauditfail`" on $Computer has been set to 1")
    }

    # If the user provided -Reboot, then reboot the computer.
    if ($Reboot.IsPresent){
        $now = [DateTime]::UtcNow.ToString("MM/dd/yyyy HH:mm:ss UTC")
        write-log("`n*********** Rebooting $Computer at $now ***********")
        restart-computer -ComputerName $Computer -Force
    }
    else{
        write-log("`n*********** Skipping rebooting $Computer ***********")
    }
}


# ********************************* MAIN PROGRAM ********************************* #

$separator = "`n------------------------------`n"

$starttime = [DateTime]::UtcNow.ToString("MM/dd/yyyy HH:mm:ss UTC")
$timer = [System.Diagnostics.Stopwatch]::StartNew()


write-log("Script started at $starttime.")

write-log("`nOptions:")

if($ComputerName){
    #Configure script to use only a single computer
    write-log("`tSingle Computer:`t$ComputerName")
    $Computers=$ComputerName
}
else{
    #Configure the script to use many computers from a file
    $Computers = get-content -LiteralPath $ComputerList
    write-log("`tMultiple Computers:")
    foreach($Computer in $Computers){write-log("`t`t$Computer")} 
}

write-log("`tLog File: $LogFile")
write-log("`tLog Type: $LogType`n")

if($NoCrashOnAudit.IsPresent){ write-log("Not resetting registry value") }
else { write-log("Restting registry value") }


# Run the Start-LogCleanupOnComputer function for every computer in the array
foreach ($Computer in $Computers) {
    write-log($separator)
    Start-LogCleanupOnComputer $Computer $LogType $EventLogBackupPath
}

$stoptime = [DateTime]::UtcNow.ToString("MM/dd/yyyy HH:mm:ss UTC")
write-log($separator)
write-log("Script completed at $stoptime.")
write-log("Script total running time was:")    
$timer.Stop()
write-log($timer.Elapsed)