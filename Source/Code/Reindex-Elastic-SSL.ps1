<#
.SYNOPSIS
This script will reindex a Relativity Data Grid index to a new shard count.

.DESCRIPTION

An ElasticSearch index shard count cannot be lowered or raised after creation.  This script was devised with Relativity Data Grid in mind.
Four parameters are required and as of this version there is not support for shield although this will be implemented in a future version.

BACKUP YOUR INDEX BEFORE RUNNING THIS SCRIPT!!!

The scripts full run will:

1.) Create a snapshot of all the indexes listed in the indexes.txt file in the same folder as the script.
2.) The mappings for the original index are applied to the new index
3.) Reindex the original indee to the orginal name with _r appended to the index name.
4.) Copy the aliases from the original index to the new index.
5.) Delete the Old index.
6.) Create a snapshot of the _r indexes.
7.) Restore to the orignal name using the _r snapshot.
8.) Delete the _r indexes.

When the operation is finished no additonal work needs to be done.

.PARAMETER nodeName
This can be any node in the cluster but the client node should be used and barring that one of the data nodes.

.PARAMETER prefix
The prefix given to the index by the Relativity Instance settings for the index prefix.

.PARAMETER indexType
This will either audit or relativity it cannot be any other word.  The prefix relativity will be for text indexes and audit for audit indexes.

.PARAMETER newShardCount
An integer value which will be your new shard count on the index generated.

.PARAMETER numberofReplicas
This will be the number of Replicas shards created for the new index.

.PARAMETER repoName
This is the registered name of the Repository in elastic search to return this value from REST use GET _snapshot
#>
[CmdletBinding()]
param(
[Parameter(Mandatory=$false)]
$nodeName = "dg-ramp-01",
[Parameter(Mandatory=$false)]
$prefix = "marley",
[Parameter(Mandatory=$false)]
$indexType = "audit",
[Parameter(Mandatory=$false)]
[int]$newShardCount = 1,
[Parameter(Mandatory=$false)]
[int]$numberOfReplicas = 1,
[Parameter(Mandatory=$false)]
[string]$repoName = "snickersbar"
)
$esPassword =  ConvertTo-SecureString "esadmin" -AsPlainText -Force
$mycreds = New-Object System.Management.Automation.PSCredential ("esadmin",$esPassword)
$contentType = 'application/json'
$getDate = Get-Date -format MM.dd.yy.HH.mm.ss
$logFile = ".\ReIndexLog.$nodeName.$getDate.txt"

<#
    Create a log file bases off the script execution time.
#>
New-Item -Path $logFile -ItemType file -force | Out-Null

<#
    Creates the Write-Log function which writes to a log file by default.
    If the script is run with the Verbose script it will log to the file and the console.
#>
Function Write-Log
{
   Param ([string]$logstring)
   Add-content $logFile -value $logstring
   Write-Verbose $logstring
}

<#
    Retrieves the list of indexes to be worked on from a file in the script drive called indexes.txt
#>
Function GetIndexList
{
[Object[]]$indexListObject = Get-Content ".\indexes.txt"
[System.Collections.ArrayList]$script:indexList = $indexListObject

Write-Log "Currently working on the following indexes:`r`n$indexList`r`nEnd List of Indexes`r`n"
}

<#
    Checks if the index exists in Elastic
    If it doesn't exist the user will be prompted to skip or remove the index from the indexes.txt file.
#>
Function CheckIndexExists 
{
    foreach ($index in $indexList){
        Try{
            Invoke-RestMethod -URI "https://$nodeName`:9200/$index" -Method 'HEAD' -ContentType 'application/json' -Credential $mycreds 2>&1 | %{ "$_" } 
            Write-Log "$index Exists.`r`n"
        }Catch [System.Net.WebException] {
            Write-Host "Could not find $index." -ForegroundColor Yellow
            Write-Log "Could not find $index.`r`n"
            Read-Host "Press return key to continue.  Ctrl + C to discontinue."
            Write-Host "Do you want to remove $index from the list?`n"
            $question = Read-Host "Press Y to remove the entry.  Press return key to continue.  Ctrl + C to discontinue."
            if($question -eq "Y"){
            Set-Content -Path ".\indexes.txt" -Value (Get-Content ".\indexes.txt" | Select-String -Pattern $index -NotMatch)
            Write-Log "Removed $index from the list.`r`nContinue from the top of the file.`r`n"
            GetIndexList
            }
        }
    }
}

function CreateOriginalSnapShot 
{
    $indexListString = $indexList -join ","
    $snapName = "original_snapshot_" + (get-date -Format MM.dd_hh.mm.ss)
    $body = @"
    {
    "indices": "$indexListString"
    }
"@
    Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName" -Method Put -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Out-Null
}

function SnapShotStatusLoop{
    Do {
        Start-Sleep -s 10
        $snapStatus = Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/_status" -Method Get -ContentType $contentType -Credential $mycreds
        $started = ($snapStatus.snapshots | Select-Object -ExpandProperty shards_stats).started
        If ($started -eq $null){
            $started = 0
        }
        $done = ($snapStatus.snapshots | Select-Object -ExpandProperty shards_stats).done
        If ($done -eq $null){
            $done = 0
        }
        if($started -ne 0 -and $done -ne 0){
            Write-Host "A snapshot is running $started shards started and $done shards done." -ForegroundColor Yellow
        }
        #$failed = (($snapStatus.snapshots | Select-Object shards_stats).shards_stats).failed
    } Until (!$snapStatus.snapshots)
}

function GetSnapShotStatus 
{
        $snapInfo = Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName" -Method Get -ContentType $contentType -Credential $mycreds
        $success = ($snapInfo.snapshots | select-object shards).shards.successful
        $total = ($snapInfo.snapshots | select-object shards).shards.total
        $failed = ($snapInfo.snapshots | select-object shards).shards.failed
        Write-Host "$success shards of $total shards were backed up for rename operation.`r`n" -ForegroundColor Green
        If ($failed -gt 0) {
            Write-Log $snapInfo.snapshots
            Write-Host "$failed shard(s) failed to backup." -ForegroundColor Red; Exit
        }
}

<#Add the transient setting for wild card usage to the cluster settins#>
function SetClusterToAllowWildCardOperations
{
    $body = "{ ""transient"": { ""action.destructive_requires_name"": ""false"" }}"
    Invoke-RestMethod -URI "https://$nodeName`:9200/_cluster/settings" -Method Put -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Out-Null
    $script:clusterSettings = Invoke-RestMethod "https://$nodeName`:9200/_cluster/settings" -Method Get -ContentType $contentType -Credential $mycreds
}

function CreateIndexListWithSuffix
{
    for($i=0;$i -lt $indexList.Count;$i++)
    {
        $script:indexList[$i] = ($indexList[$i]) +"_r"
    }
        
}

function CreateSnapShot 
{
    $indexListString = $indexList -join ","
    $script:snapName = "snapshot_" + (get-date -Format MM.dd_hh.mm.ss)
    $body = @"
    {
    "indices": "$indexListString"
    }
"@
    Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName" -Method Put -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Out-Null
}

function RestoreSnapShotRemoveUnderscoreR 
{
    $body = @"
    {
     "indices": "$indexListString",
     "ignore_unavailable": "true",
     "include_global_state": false,
     "rename_pattern": "^(.*).{2}",
     "rename_replacement": "`$1"
    }
"@
    Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName/_restore" -Method Post -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Out-Null
    Write-Host "Restoring indexes to orginal names.`r`n" -ForegroundColor Green
}

function RemoveUnderScoreRIndexes {
    foreach ($index in $indexList){
    Invoke-RestMethod -Uri "https://$nodeName`:9200/$index" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
    }

}

function SetClusterToDisallowWildCardOperations
{
    $body = "{ ""transient"": { ""action.destructive_requires_name"": ""true"" }}"
    Invoke-RestMethod -URI "https://$nodeName`:9200/_cluster/settings" -Method Put -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Out-Null
}

GetIndexList

Write-Log "The list of indexes before index check is $indexList.`r`n"

CheckIndexExists

Write-Log "The list of indexes after index check is $indexList.`r`n"
Write-Log "Begin reindex on all indexes in the indexes.txt file.`r`n"
$indexListCount = $indexList.Count
Write-Log "The index count is $indexListCount.`r`n"

Write-Host "Creating a snapshot of the indexes at this time.`r`n" -foregroundcolor Green

CreateOriginalSnapShot

SnapShotStatusLoop

GetSnapShotStatus

<#
    Begin the for each loop which will reindex all the items in indexList variable.
#>
$i = 1
Foreach ($originalIndex in $indexList) 
{
    $startTime = Get-Date -format MM.dd.yy.HH.mm.ss
    Write-Log "The data time is $startTime `r`n"
    Write-Log "Working on index number $i in the list of indexes.`r`n"
    Write-Log "Original index name: $originalIndex.`r`n"

    <#Calls ElasticSearch and returns the variable oldDocsCount which is the number of documents in the original index.#>
    Function GetDocumentCountOldIndex {
        $script:oldDocsCount = Invoke-RestMethod -Uri "https://$nodeName`:9200/_cat/indices?v&index=$originalIndex" -Method Get -ContentType $contentType -Credential $mycreds | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count
        Write-Log "The document count of the old index is $oldDocsCount.`r`n"
    }

    <#Increments $index and returns $indexNew the name of the target for the reindex operation.#>
    Function NewIndexName {
        $script:indexNew = "$originalIndex`_r"  
        Write-Log "The new index name will be $indexNew`r`n" 
    }

    <#Retrieves three return values of the variables readAliasOld, writeAliasOld, and verifyAliasOld for use by GenerateAliases.#>
    Function GetOldAlias {
        Write-Log "Retrieving the Aliases from $originalIndex.`r`n"
        $aliases = (Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/_alias/*" -Method 'GET' -ContentType $contentType -Credential $mycreds).$originalIndex.aliases  
        $aliases = ($aliases | Get-Member -type NoteProperty).Name
        $script:readAliasOld = $aliases -like "*read"
        $script:writeAliasOld = $aliases -like "*write"
        $script:verifyAliasOld = $aliases -like "*verify"
    }

    <#Calls ElasticSearch and creates the index the function returns void.#>
    Function CreateNewIndex {
        Try{
            Write-Log "Attempting to create $indexNew.`r`n"
            Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew" -Method 'PUT' -ContentType $contentType -Credential $mycreds -Body "{ ""settings"": { ""index"":{ ""number_of_shards"": $newShardCount, ""number_of_replicas"": $numberOfReplicas }}}" 2>&1 | %{ "$_" } | Out-Null
        }
        Catch [System.Net.WebException] {
          ` Write-Log "Could not create $indexNew."
            $ErrorMessage = $_.Exception.Message
            $ErrorName = $_.Exception.GetType().FullName
            Write-Host "An Execption has occurred. When attempting to create $indexNew`nThe error message will be logged." -ForegroundColor Red;
            Write-Log "The Exeception Message is:`r`n $ErrorMessage.`r`n"
            Write-Log "The Exeception Name is:`r`n $ErrorName.`r`n"
        }
    }

    <#Gets the mappings from the index to be reindex#>
    Function GetMappingsOldIndex {
        Write-Log "Attempting to get mappings from $originalIndex.`r`n"
        (Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/_mappings" -Method 'GET' -ContentType $contentType -Credential $mycreds -OutFile .\json.txt)
        $mappings = (Get-Content .\json.txt).ToString()
        $mappings = $mappings -replace "{`"$originalIndex`":{`"mappings`":"
        $script:mappings = $mappings.Substring(0,$mappings.Length-2) 
    }
    
    <#Applies the mappings to the new index in Elastic.#>
    Function ApplyMappingsToNewIndex {
        Write-Log "Attempting to apply mappings from $originalIndex to $indexNew.`r`n"
        Try{
            Invoke-RestMethod -URI "https://$nodeName`:9200//_mappings/$indexType" -Method 'PUT' -ContentType $contentType -Credential $mycreds -Body $mappings 2>&1 | %{ "$_" } | Out-Null
            Write-Log "Applied the mappings from the old index to the new index."
        }
        Catch [System.Net.WebException] {Write-Log "Failed to copy the mappings to the new index.`r`n"}
    }

    <#
        Reindexes to the new index.  
        If the call is returned before reindexing is complete function falls directly into WaitForComplete function.
    #>
    Function Reindex {
        Write-Log "Start reindex from $originalIndex to $indexNew.`r`n"
        Try {
        Invoke-RestMethod -Uri "https://$nodeName`:9200/_reindex" -Method Post -ContentType $contentType -Credential $mycreds -Body "{ ""source"": { ""index"": ""$originalIndex"" }, ""dest"": { ""index"": ""$indexNew"" }}"
        }
        Catch [System.Net.WebException] {Write-Log "Reindex Failed from $originalIndex to $indexNew.`r`nAbort!`r`n"}
    }

    <#
        Compares the document counts as reindexing process is running.  
        It is also the break point of the Do Until loop in WaitForComplete.
    #>
    Function CompareDocumentCounts {
        $script:newDocsCount = Invoke-RestMethod -Uri "https://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType -Credential $mycreds | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

        if($oldDocsCount -eq $newDocsCount){
            Write-Log "The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount.`r`n"
        }else{
            $percentComplete = (($newDocsCount/$oldDocsCount)*100)
            Write-Host "Reindexing Documents...$percentComplete% Complete" -ForegroundColor Yellow;
            Write-Log "Reindexing Documents from $originalIndex to $indexNew..." (($newDocsCount/$oldDocsCount)*100) "% Complete" 
        }
    }

    <#Uses CompareDocumentCounts to ensure the script does not proceed until reindexing is completed.#>
    Function WaitForComplete {
        Do {
            Write-Log "Waiting for the operation to complete.`r`nSleep for 15 seconds.`r`n"
            Sleep -Seconds 15
            CompareDocumentCounts
            $script:taskStatus = Invoke-RestMethod -Uri "https://$nodeName`:9200/_tasks?actions=*reindex" -Method Get -ContentType $contentType -Credential $mycreds
            Write-Log "The task status is currently $taskStatus.nodes. Will be blank for ended task."
            If ((new-object -type PSObject -Property @{ nodes = "" }).nodes -eq $taskStatus.nodes){
                Write-Log "The ES task stopped before the counts were equal."     
            }
        } Until ($newDocsCount -eq $oldDocsCount)
    }

    Function FinalCompare {
        $script:newDocsCount = Invoke-RestMethod -Uri "https://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType -Credential $mycreds | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count
        if($oldDocsCount -eq $newDocsCount){
            Write-Log "The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount.`r`n"
            Write-Host "Reindexing Completed from $originalIndex to $indexNew... " (($newDocsCount/$oldDocsCount)*100) "% Complete" -ForegroundColor Green
        }else{
            Write-Host "Check the Log the counts for the indexes $oldDocsCount : $newDocsCount do not match." -ForegroundColor Red;
            Write-Log "Count Error! The count for $originalIndex & $indexNew do not match $oldDocsCount : $newDocsCount.`r`n" ; Exit
        }
    }

    <#Removes the Aliases for both old and new indexes#>
    Function RemoveAliases {
        Write-Log "Removing the Aliases from $originalIndex and $indexNew.`r`n"
        Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/_alias/*" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/*" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
    }

    <#Applies the aliases from the old index to the new index in Elastic#>
    Function GenerateAliases {
        Write-Log "Adding the aliases from $originalIndex to $indexNew.`r`n"
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/$readAliasOld" -Method Put -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/$writeAliasOld" -Method Put -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/$verifyAliasOld" -Method Put -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
    }

    <#Removes the old index.#>
    Function DeleteOldIndex {
        Write-Log "Delete $originalIndex.`r`n"
        Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Out-Null
        Write-Verbose "The old index: $originalIndex has been deleted."
    }


    <#
        Main Function where the functions in the for each are called in order.
    #>
    Function ReIndexMany {
        NewIndexName
        
        Write-Host "Starting reindexing operations on: $originalIndex to $indexNew.`n" -ForegroundColor Cyan;

        GetDocumentCountOldIndex

        Write-Host "The new index will be called: $indexNew" -ForegroundColor Green

        GetOldAlias

        Write-Host "Creating the new index:" $indexNew -ForegroundColor Green

        CreateNewIndex

        GetMappingsOldIndex

        ApplyMappingsToNewIndex

        Write-Host "Reindexing $index to $indexNew" -ForegroundColor Green

        Reindex

        CompareDocumentCounts

        WaitForComplete

        FinalCompare

        RemoveAliases

        GenerateAliases

        DeleteOldIndex

        Write-LOg "Finished Script run on $originalIndex."
        $i++
    }
    ReIndexMany


}

<#
    Create a backup of the _r indexes and restore them to the orginal name
#>

SetClusterToAllowWildCardOperations

[string]$settings = $clusterSettings.transient.action.destructive_requires_name; Write-Log "Action destructive_requires_name set to $settings.`r`n"

CreateIndexListWithSuffix

Write-Log "The indicies to snapshot are $indexList.`r`n"

CreateSnapShot

SnapShotStatusLoop

GetSnapShotStatus

RestoreSnapShotRemoveUnderscoreR

RemoveUnderScoreRIndexes

SetClusterToDisallowWildCardOperations