<#
.SYNOPSIS
This script will reindex a Relativity Data Grid index to a new shard count.

.DESCRIPTION

An ElasticSearch index shard count cannot be lowered or raised after creation.  This script was devised with Relativity Data Grid in mind.
Four parameters are required and as of this version there is not support for shield although this will be implemented in a future version.

BACKUP YOUR INDEX BEFORE RUNNING THIS SCRIPT!!!

The scripts full run will:

1.) Create a new index which will be the same name incremented by one as a target for the operation.
2.) Copy the mappings from the old index to the new target index.
3.) Reindex the documents from the old index to the new target index.
4.) Remove the mappings created by default from both indexes.
5.) Add the mappings from the old index to the new index.
6.) Delete the old index.

When the operation is finished no additonal work needs to be done.

.PARAMETER nodeName
This can be any node in the cluster but the client node should be used and barring that one of the data nodes.

.PARAMETER caseArtifactID
The Relativity case artifact ID includeing the edds prefix.  This will be the each name of the Relativity Case database.

.PARAMETER prefix
This will either audit or relativity it cannot be any other word.  The prefix relativity will be for text indexes and audit for audit indexes.

.PARAMETER newShardCount
An integer value which will be your new shard count on the index generated.

.PARAMETER numberofReplicas
This will be the number of Replicas shards created for the new index.

.PARAMETER shieldState
shieldState is not yet implemented and will be used to pass the esusers name and password to the cluster.
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
[int]$numberOfReplicas = 1
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
Function Write-Log{
   Param ([string]$logstring)
   Add-content $logFile -value $logstring
   Write-Verbose $logstring
}

<#
    Retrieves the list of indexes to be worked on from a file in the script drive called indexes.txt
#>
Function GetIndexList{
[Object[]]$indexListObject = Get-Content ".\indexes.txt"
[System.Collections.ArrayList]$script:indexList = $indexListObject

Write-Log "Currently working on the following indexes:`r`n$indexList`r`nEnd List of Indexes`r`n"
}
GetIndexList

Write-Log "The list of indexes before index check is $indexList.`r`n"

<#
    Checks if the index exists in Elastic
    If it doesn't exist the user will be prompted to skip or remove the index from the indexes.txt file.
#>
Function CheckIndexExists {
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
CheckIndexExists

Write-Log "The list of indexes after index check is $indexList.`r`n"
Write-Log "Begin reindex on all indexes in the indexes.txt file.`r`n"
$indexListCount = $indexList.Count
Write-Log "The index count is $indexListCount.`r`n"

<#
    Begin the for each loop which will reindex all the items in indexList variable.
#>
$i = 1
Foreach ($originalIndex in $indexList) {
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
            Write-Log "Waiting for the operation to complete.`r`nSleep for 5 seconds.`r`n"
            Sleep -Seconds 15
            CompareDocumentCounts
            $script:taskStatus = Invoke-RestMethod -Uri "https://$nodeName`:9200/_tasks?actions=*reindex" -Method Get -ContentType $contentType -Credential $mycreds
            Write-Log "The task status is currently $taskStatus.nodes.  Will be blank for ended task."
            If ((new-object -type PSObject -Property @{ nodes = "" }).nodes -eq $taskStatus.nodes){
                Write-Log "The ES task stopped before the counts were equal." ; Break      
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
    Function RunTime {
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
    RunTime
}