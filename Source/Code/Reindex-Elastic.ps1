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
[Parameter(Mandatory=$true)]
$nodeName = "cs-mv1-caw",
[Parameter(Mandatory=$true)]
$caseArtifactID = "edds1076732",
[Parameter(Mandatory=$true)]
$prefix = "audit",
[Parameter(Mandatory=$true)]
[int]$newShardCount = '2',
[Parameter(Mandatory=$true)]
[int]$numberOfReplicas = '1',
[bool]$shieldState = $false
)

$contentType = 'application/json'

#Returns $index the name of the index for reindexing. 
Function FindIndex {
    #$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $esUsername,$esPassword)))

    Try{
        $callES = Invoke-RestMethod -URI "http://$nodeName`:9200/_cat/indices?v&h=index" -Method 'GET' -ContentType 'application/json' 

        [array]$indexes =  $callES | select -Property index -ExpandProperty index

        $index = ($indexes -like "$prefix*$caseArtifactID*")
        [string]$script:index = $index
        
    }
    Catch [System.Net.WebException] {
       Write-Host "Could not connect to elastic at $nodeName." -ForegroundColor Red;
       Exit
    }   
}

#Increments $index and returns $indexNew the name of the target for the reindex operation.
Function NewIndexName {

    $indexStringArray = $index.ToCharArray()
    [int]$short = $indexStringArray.Length - 1
    [int]$lastDigit = [convert]::ToInt32($indexStringArray.GetValue($short), 10)
    [int]$lastPlusOne = $lastDigit + 1
    [string]$lastString = $lastPlusOne
    [char]$lastChar = $lastString
    
    $script:indexNew = $index.Substring(0,$index.Length-1) + $lastString
    
}

#Calls ElasticSearch and creates the index the function returns void.
Function CreateNewIndex {

    Try{
        Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew" -Method 'PUT' -ContentType $contentType -Body "{ ""settings"": { ""index"":{ ""number_of_shards"": $newShardCount, ""number_of_replicas"": $numberOfReplicas }}}"
    }
    Catch [System.Net.WebException] {
       Write-Host "Could not connect to elastic at $nodeName." -ForegroundColor Red;
    }

}

#Calls ElasticSearch and gets the mappings of the original index.  Returns $mappings
Function GetMappingsOldIndex {
    $mappings = (Invoke-RestMethod -URI "http://$nodeName`:9200/$index/_mappings" -Method 'GET' -ContentType $contentType).ToString()

    $mappings = $mappings -replace "{`"$index`":{`"mappings`":"

    $script:mappings = $mappings.Substring(0,$mappings.Length-2) 
}

#Applies the mappings to the new index returns void.
Function ApplyMappingsToNewIndex {

    Try{
        Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_mapping/$prefix" -Method 'PUT' -ContentType $contentType -Body $mappings
    }
    Catch [System.Net.WebException] {}
}

#Reindexes to the new index and returns void.  If the operation times the function falls directly into WaitForComplete function.
Function Reindex {
    Try {
    Invoke-RestMethod -Uri "http://$nodeName`:9200/_reindex" -Method Post -ContentType $contentType -Body "{ ""source"": { ""index"": ""$index"" }, ""dest"": { ""index"": ""$indexNew"" }}" -ErrorAction SilentlyContinue
    }
    Catch [System.Net.WebException] {}
}

#Calls ElasticSearch and returns $oldDocsCount which is the number of documents in the original index.
Function GetDocumentCountOldIndex {

    $script:oldDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$index" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

}

#Compares the document counts as reindexing process the function part of the WaitForComplete Fuction.  It is also the break point of the Do Until loop in WaitForComplete.
Function CompareDocumentCounts {

    $script:newDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

    if($oldDocsCount -eq $newDocsCount){
        Write-Host "The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount" -ForegroundColor Green
    }else{
        Write-Host "Reindexing Documents from $index to $indexNew : " (($newDocsCount/$oldDocsCount)*100) "% Complete" -ForegroundColor Yellow
    }
}

#Final Test to see if the document counts match the script will exit if the count is off at this point.
Function CompareDocumentCountsTest {

    $script:oldDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$index" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

    $script:newDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

    if($oldDocsCount -eq $newDocsCount){
        Write-Host "The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount" -ForegroundColor Green
    }else{
        Write-Host "The document count does not match: $oldDocsCount : $newDocsCount " -ForegroundColor Yellow
        Exit
    }
}

#Uses CompareDocumentCounts to ensure the script does not proceed until reindexing is completed.
Function WaitForComplete {
    Do {
    cls
    CompareDocumentCounts
    Sleep -Seconds 10
    } Until ($newDocsCount -eq $oldDocsCount)
}

#Retrieves three return values $readAliasOld, $writeAliasOld, and verifyAliasOld for use by GenerateAliases.
Function GetOldIndexAlias {

    $aliases = Invoke-RestMethod -URI "http://$nodeName`:9200/$index/_alias/*" -Method 'GET' -ContentType $contentType  | select -Property $index -ExpandProperty $index | select -Property aliases
    $aliases | gm -type NoteProperty | ForEach-Object {
    $value = $aliases.aliases
    [array]$aliasesArray = ($value | gm | select -Property Name -ExpandProperty Name).Split()
    $script:readAliasOld = $aliasesArray -like "*read"
    $script:writeAliasOld = $aliasesArray -like "*write"
    $script:verifyAliasOld = $aliasesArray -like "*verify"
  }
}

#Removes the Aliases for both old and new indexes, returns void.
Function RemoveAliases {

    $subString = ($index.Substring(0,$index.Length-1))
    Invoke-RestMethod -URI "http://$nodeName`:9200/$subString*/_alias/*" -Method Delete -ContentType $contentType
    Write-Verbose "Removing the Aliases from $index and $indexNew"
}

#Calls ElasticSearch and applies the alias from the old index to the new index, returns void.
Function GenerateAliases {

    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$readAliasOld" -Method Put -ContentType $contentType 
    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$writeAliasOld" -Method Put -ContentType $contentType
    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$verifyAliasOld" -Method Put -ContentType $contentType
}

#Removes the old index, returns void.
Function DeleteOldIndex {

    CompareDocumentCounts
    Invoke-RestMethod -URI "http://$nodeName`:9200/$index/" -Method Delete -ContentType $contentType
    Write-Host "The old index: $index has been deleted."
}

#Main Function where the functions in the script are called in order.
Function RunTime {
    Write-Host "The case ArtifactID of the case to reindex: $caseArtifactID.`n" -ForegroundColor Cyan;

    Write-Host "Checking for the index.`n" -ForegroundColor Green;

    FindIndex

    Write-Host "Found the index called: " $index "`n" -ForegroundColor Green

    GetDocumentCountOldIndex

    NewIndexName

    Write-Host "The new index will be called: " $indexNew "`n" -ForegroundColor Green

    Write-Host "Creating the new index:" $indexNew -ForegroundColor Green

    CreateNewIndex

    GetMappingsOldIndex

    ApplyMappingsToNewIndex

    Write-Host "Reindexing $index to $indexNew" -ForegroundColor Green

    Reindex

    CompareDocumentCounts

    WaitForComplete

    CompareDocumentCountsTest

    GetOldIndexAlias

    RemoveAliases

    GenerateAliases

    DeleteOldIndex
}

RunTime