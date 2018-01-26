<#
.SYNOPSIS
This script will reindex a Relativity Data Grid index to a new shard count.

.DESCRIPTION

An ElasticSearch index shard count cannot be lowered or raised after creation.  This script was devised with Relativity Data Grid in mind.
Four parameters are required and as of this version there is not support for shield although this will be implemented in a future version.

BACKUP YOUR INDEX BEFORE RUNNING THIS SCRIPT!!!

The scripts full run will:


1.) Loop through the list. 
2.) Create a Backup of each individual entry
3.) Reindex the original to the orginal name with _r appended to the index name.
4.) The mappings for each original index are applied to a new index.
5.) Copy the aliases from the original index to the new index.
6.) Create a snapshot of the _r indexes.
7.) Delete the original index.
8.) Restore and rename using the orignal name from the _r snapshot.
9.) Delete the _r indexes.
10.)Loop to step 1 for the remaining entries.

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

.EXAMPLE

.\Reindex-Elastic-SSL.ps1 -nodeName clientnodename -prefix audit -indexType audit -newShardCount 2 -numberOfReplicas 1 -repoName datagridbackup

Run with normal logging.

.EXAMPLE

.\Reindex-Elastic-SSL.ps1 -nodeName clientnodename -prefix audit -indexType audit -newShardCount 2 -numberOfReplicas 1 -repoName datagridbackup -Verbose 4> verbose.log

Run with normal logging and a verbose log file of all actions.

#>

#region Parameters and variables
[CmdletBinding()]
param(
[Parameter(Mandatory=$true)]
$nodeName,
[Parameter(Mandatory=$true)]
$prefix,
[Parameter(Mandatory=$true)]
$indexType,
[Parameter(Mandatory=$true)]
[int]$newShardCount,
[Parameter(Mandatory=$true)]
[int]$numberOfReplicas,
[Parameter(Mandatory=$true)]
[string]$repoName
)
$esPassword =  ConvertTo-SecureString "esadmin" -AsPlainText -Force
$mycreds = New-Object System.Management.Automation.PSCredential ("esadmin",$esPassword)
$contentType = 'application/json'
$getDate = Get-Date -format MM.dd.yy.HH.mm.ss
$logFile = ".\ReIndexLog.$nodeName.$getDate.txt"
#endregion

#region Define functions

#region Write-Log function. Accepts a string to write to the log file.

Function Write-Log
{
   Param ([string]$logstring)
   Add-content $logFile -value $logstring
}

#endregion

#region Create a log file date stamped log file.

New-Item -Path $logFile -ItemType file -force | Write-Log

#endregion

#region GetIndexList function. Retrieves the list of indexes to be worked on from indexes.txt located in the script's folder.

Function GetIndexList
{
    [Object[]]$indexListObject = Get-Content ".\indexes.txt"
    [System.Collections.ArrayList]$script:indexList = $indexListObject
    Write-Log "<<Currently working on the following indexes>>:`r`n"
    Foreach($index in $indexList){
        Write-Log $index
    }
    Write-Log "`r`n<<End List>>`r`n"
}

#endregion

#region CheckIndexExists function.  Checks for existence of the index names in $indexList from GetIndexList function in Elastic.

Function CheckIndexExists 
{
    foreach ($index in $indexList){
        Try{
            Invoke-RestMethod -URI "https://$nodeName`:9200/$index" -Method 'HEAD' -ContentType 'application/json' -Credential $mycreds 2>&1 | %{ "$_" } 
            Write-Log "$index`r<<Found>>`r"
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

#endregion

#region CreateOriginalSnapShot function.  Creates a backup of the indexes listed in $indexList.

function CreateOriginalSnapShot 
{
    $script:snapName = "original_snapshot_" + (get-date -Format MM.dd_hh.mm.ss)
    $body = @"
    {
    "indices": "$originalIndex"
    }
"@
    Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName" -Method Put -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Write-Log

}

#endregion

#region SnapShotStatusLoop function.  A loop which queries the _snapshot/_status endpoint in ES.  The loops is broken when _snapshot/_status endpoint returns NULL.

function SnapShotStatusLoop{
    Do {
        Start-Sleep -s 10
        $snapStatus = Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/_status" -Method Get -ContentType $contentType -Credential $mycreds
        $total = ($snapStatus.snapshots | Select-Object -ExpandProperty shards_stats).total
        If ($started -eq $null){
            $started = 0
        }
        $done = ($snapStatus.snapshots | Select-Object -ExpandProperty shards_stats).done
        If ($done -eq $null){
            $done = 0
        }
        if($started -ne 0 -and $done -ne 0){
            Write-Host "A snapshot is running on $total shards started and $done shards done." -ForegroundColor Yellow
        }
    } Until (!$snapStatus.snapshots)
}

#endregion

#region GetSnapShotStatus function. Uses an elastic call to verify the snapshot.  Breaks the run if failed shards are found.

function GetSnapShotStatus 
{
        $snapInfo = Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName" -Method Get -ContentType $contentType -Credential $mycreds
        $success = ($snapInfo.snapshots | select-object shards).shards.successful
        $total = ($snapInfo.snapshots | select-object shards).shards.total
        $failed = ($snapInfo.snapshots | select-object shards).shards.failed
        Write-Host "$success shards of $total shards were backed up.`r`n" -ForegroundColor Green
        If ($failed -gt 0) {
            Write-Log $snapInfo.snapshots
            Write-Host "$failed shard(s) failed to backup." -ForegroundColor Red; Exit
        }
}

#endregion

#region CreateIndexListWithSuffix function.  Appends _r to each entry in $indexList.

function CreateIndexListWithSuffix
{
    for($i=0;$i -lt $indexList.Count;$i++)
    {
        $script:indexList[$i] = ($indexList[$i]) +"_r"
    }
        
}

#endregion

#region CreateSnapShot function.  Creates a snapshot of the indexes in $indexList.

function CreateSnapShot 
{    
    $script:snapName = "snapshot_" + (get-date -Format MM.dd_hh.mm.ss)
    Write-Log "Backing up $indexNew to snapshot name $snapName."
    Write-Host "Backing up $indexNew to snapshot name $snapName." -ForegroundColor Green
    $body = @"
    {
    "indices": "$indexNew"
    }
"@
    Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName" -Method Put -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Write-Log
}

#endregion

#region RestoreSnapShotRemoveUnderscoreR function.  Restores the indexes from backup to their original name.

function RestoreSnapShotRemoveUnderscoreR 
{
    $body = @"
    {
     "indices": "$indexNew",
     "ignore_unavailable": "true",
     "include_global_state": false,
     "rename_pattern": "^(.*).{2}",
     "rename_replacement": "`$1"
    }
"@
    Invoke-RestMethod -Uri "https://$nodeName`:9200/_snapshot/$repoName/$snapName/_restore" -Method Post -ContentType $contentType -Credential $mycreds -Body $body 2>&1 | %{ "$_" } | Write-Log
    Write-Host "Restoring $indexNew from backup to original name.`r`n" -ForegroundColor Green
    Write-Log "Restoring $indexNew from backup to original name.`r`n"
}

#endregion

#region RemoveUnderScoreRIndexe.  Deletes the _r index called $indexNew

function RemoveUnderScoreRIndex {

    Invoke-RestMethod -Uri "https://$nodeName`:9200/$indexNew" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log

}

#endregion

#region Check for existence of indexes corresponding to values listed in the $indexList variable.

GetIndexList

CheckIndexExists

Write-Log "<<Begin reindex on all indexes in the indexes.txt file.>>`r"

Write-Log ("<<The index count is " + $indexList.Count.ToString() + ".>>")


#endregion

#region Begin the foreach loop to reindex each entry in the $indexList variable

Foreach ($originalIndex in $indexList) 
{
    #region Log Entry with Star Date
    $startTime = Get-Date -format MM.dd.yy.HH.mm.ss
    Write-Log "Captains log, Star date $startTime `r`n"
    Write-Log "<<Original index name: $originalIndex.>>`r`n"
    #endregion

    #region Snapshot the $orginalIndex

    Write-Host "Creating snapshot of index $originalIndex." -ForegroundColor Green

    CreateOriginalSnapShot

    

    SnapShotStatusLoop

    GetSnapShotStatus

    #endregion

    #region GetDocumentCountOldIndex function.  Returns $oldDocsCount the number of documents in $originalIndex.
    Function GetDocumentCountOldIndex {
        $script:oldDocsCount = Invoke-RestMethod -Uri "https://$nodeName`:9200/_cat/indices?v&index=$originalIndex" -Method Get -ContentType $contentType -Credential $mycreds | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count
        Write-Log "<<The document count of the old index is $oldDocsCount.>>`r`n"
    }
    #endregion

    #region NewIndexName function. Appends $orginalIndex with a _r and sets the value to $indexNew.
    Function NewIndexName {
        $script:indexNew = "$originalIndex`_r"  
        Write-Log "<<The new index name will be $indexNew.>>`r`n" 
    }
    #endregion

    #region GetOldAlias function. Retrieves three return values of the variables $readAliasOld, $writeAliasOld, and $verifyAliasOld for use by GenerateAliases.
    Function GetOldAlias {
        Write-Log "<<Retrieving the Aliases from $originalIndex.>>`r`n"
        $aliases = (Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/_alias/*" -Method 'GET' -ContentType $contentType -Credential $mycreds).$originalIndex.aliases  
        $aliases = ($aliases | Get-Member -type NoteProperty).Name
        $script:readAliasOld = $aliases -like "*read"
        $script:writeAliasOld = $aliases -like "*write"
        $script:verifyAliasOld = $aliases -like "*verify"
    }
    #endregion

    #region CreateNewIndex function.  Creates the target index.
    Function CreateNewIndex {
        Try{
            Write-Log "<<Attempting to create $indexNew.>>"
            Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew" -Method 'PUT' -ContentType $contentType -Credential $mycreds -Body "{ ""settings"": { ""index"":{ ""number_of_shards"": $newShardCount, ""number_of_replicas"": $numberOfReplicas }}}" 2>&1 | %{ "$_" } | Write-Log
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
    #endregion

    #region GetMappingsOldIndex function. Gets the mappings from the orginal index.
    Function GetMappingsOldIndex {
        Write-Log "<<Attempting to get mappings from $originalIndex.>>"
        (Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/_mappings" -Method 'GET' -ContentType $contentType -Credential $mycreds -OutFile .\json.txt ) 2>&1 | %{ "$_" }
        $mappings = (Get-Content .\json.txt).ToString()
        $mappings = $mappings -replace "{`"$originalIndex`":{`"mappings`":"
        $script:mappings = $mappings.Substring(0,$mappings.Length-2) 
    }
    #endregion
    
    #region ApplyMappingsToNewIndex function. Applies the mappings to the new index in Elastic.
    Function ApplyMappingsToNewIndex {
        Write-Log "<<Attempting to apply mappings from $originalIndex to $indexNew.>>`r`n"
        Try{
            Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_mappings/$indexType" -Method 'PUT' -ContentType $contentType -Credential $mycreds -Body $mappings 2>&1 | %{ "$_" } | Write-Log
        }
        Catch [System.Net.WebException] {
            Write-Log "Failed to copy the mappings to the new index.`r`n"
        }
    }
    #endregion

    #region Reindex function. Calls the reindex API in Elastic.  If the call is returned before reindexing is complete function falls directly into WaitForComplete function.
    
    Function Reindex {
        Write-Log "<<Start reindex from $originalIndex to $indexNew.>>`r`n"
        Try {
        Invoke-RestMethod -Uri "https://$nodeName`:9200/_reindex" -Method Post -ContentType $contentType -Credential $mycreds -Body "{ ""source"": { ""index"": ""$originalIndex"" }, ""dest"": { ""index"": ""$indexNew"" }}"
        }
        Catch [System.Net.WebException] {Write-Log "Reindex Failed from $originalIndex to $indexNew.`r`nAbort!`r`n"}
    }
    #endregion

    #region CompareDocumentCounts function. Compares the document counts as reindexing process is running.  It is also the break point of the Do Until loop in WaitForComplete.   
    
    Function CompareDocumentCounts {
        $script:newDocsCount = Invoke-RestMethod -Uri "https://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType -Credential $mycreds | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

        if($oldDocsCount -eq $newDocsCount){
            Write-Log "<<The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount.>>`r`n"
        }else{
            $percentComplete = (($newDocsCount/$oldDocsCount)*100)
            Write-Host "Reindexing Documents...$percentComplete% Complete" -ForegroundColor Yellow;
            Write-Log "Reindexing Documents from $originalIndex to $indexNew..." (($newDocsCount/$oldDocsCount)*100) "% Complete" 
        }
    }
    #endregion

    #region WaitForComplete function.  Uses CompareDocumentCounts to ensure the script does not proceed until reindexing is completed.
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
    #endregion

    #region FinalCompare function.  Does another compare to ensure the index is at 100% before proceeding.

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
    #endregion

    #region RemoveAliases function.  Removes the aliases for both old and new indexes.

    Function RemoveAliases {
        Write-Log "<<Removing the Aliases from $originalIndex and $indexNew.>>"
        Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/_alias/*" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/*" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log
    }
    #endregion

    #region GenerateAliases function.  Applies the aliases from the old index to the new index.
    Function GenerateAliases {
        Write-Log "<<Adding the aliases from $originalIndex to $indexNew.>>"
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/$readAliasOld" -Method Put -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/$writeAliasOld" -Method Put -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log
        Invoke-RestMethod -URI "https://$nodeName`:9200/$indexNew/_alias/$verifyAliasOld" -Method Put -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log
    }
    #endregion

    #region DeleteOldIndex function. Deletes the old index.

    Function DeleteOldIndex {
        Write-Log "<<Delete $originalIndex.>>"
        Invoke-RestMethod -URI "https://$nodeName`:9200/$originalIndex/" -Method Delete -ContentType $contentType -Credential $mycreds 2>&1 | %{ "$_" } | Write-Log
        Write-Verbose "The old index: $originalIndex has been deleted."
    }
    #endregion

    #region Main function.  Calls the functions to reindex the entry from $indexList    #>

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

        CreateSnapShot

        SnapShotStatusLoop

        GetSnapShotStatus

        RestoreSnapShotRemoveUnderscoreR

        SnapShotStatusLoop

        GetSnapShotStatus

        RemoveUnderScoreRIndex

        Write-Log "<<Finished Script run on $originalIndex.>>"
        $i++
    }
    ReIndexMany

    #endregion
}
#endregion