#Data Grid Reindex Script#

param(
$nodeName = "cs-mv1-agtfs",
$caseArtifactID = "edds1020964",
$prefix = "audit",
[int]$newShardCount = '12',
[int]$numberOfReplicas = '1',
[bool]$shieldState = $false
)

$contentType = 'application/json'

#Get the user input at some point has this read from a file

Write-Host "The case ArtifactID of the case to reindex: $caseArtifactID.`n" -ForegroundColor Cyan;

Write-Host "The index type to change is $prefix.`n" -ForegroundColor Cyan;

Write-Host "Checking for the index.`n"

Function FindIndex {
    #$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $esUsername,$esPassword)))

    Try{
    [array]$responce = (Invoke-RestMethod -URI "http://$nodeName`:9200/*$caseArtifactID*" -Method 'GET' -ContentType 'application/json') |
     gm | select -Property Name -ExpandProperty Name -ErrorAction Stop
    }
    Catch [System.Net.WebException] {
       Write-Host "Could not connect to elastic at $nodeName." -ForegroundColor Red;
       Exit
    } 
    $responce -like "$prefix*$caseArtifactID*"
}

$index = FindIndex

Write-Host "Found the index called: " $index "`n" -ForegroundColor Green

Function ShardNumber {

    Try{
    [array]$responce = (Invoke-RestMethod -URI "http://$nodeName`:9200/$index/_settings" -Method 'GET' -ContentType $contentType) |
    select -Property $index -ExpandProperty $index
    $responce |
     select -Property settings -ExpandProperty settings |
     select -Property index -ExpandProperty index |
     select -Property number_of_shards -ExpandProperty number_of_shards  
    }
    Catch [System.Net.WebException] {
       Write-Host "Could not connect to elastic at $nodeName." -ForegroundColor Red;
       Exit
    }     
}

$numberOfShards = ShardNumber

Write-Host "The index has $numberOfShards number of shards.`n" -ForegroundColor Green

Function NewIndexName {

    $indexStringArray = $index.ToCharArray()
    [int]$short = $indexStringArray.Length - 1
    [int]$lastDigit = [convert]::ToInt32($indexStringArray.GetValue($short), 10)
    [int]$lastPlusOne = $lastDigit + 1
    [string]$lastString = $lastPlusOne
    [char]$lastChar = $lastString
    
    $index.Substring(0,$index.Length-1) + $lastString
    
}

$indexNew = NewIndexName

Write-Host "The new index will be called: " $indexNew "`n" -ForegroundColor Green

Function CreateNewIndex {

    Try{
        Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew" -Method 'PUT' -ContentType $contentType -Body "{ ""settings"": { ""index"":{ ""number_of_shards"": $newShardCount, ""number_of_replicas"": $numberOfReplicas }}}"
    }
    Catch [System.Net.WebException] {
       Write-Host "Could not connect to elastic at $nodeName." -ForegroundColor Red;
    }

}

Write-Host "Creating the new index:" $indexNew -ForegroundColor Green

CreateNewIndex

Function Reindex {

    Try{
        Invoke-RestMethod -Uri "http://$nodeName`:9200/_reindex" -Method Post -ContentType $contentType -Body "{ ""source"": { ""index"": ""$index"" }, ""dest"": { ""index"": ""$indexNew"" }}" -ErrorAction Stop
        sleep -Seconds 5

    }
    Catch [System.Net.WebException] {
        $ErrorMessage = $_.Exception.Message
        $ErrorName = $_.Exception.GetType().FullName
        Write-Host "An Execption has occurred.`n"  -ForegroundColor Red;
        Write-Output "The Exeception Name is:`n $ErrorName.`n"
        Write-Output "The Exeception Message is:`n $ErrorMessage.`n"    }


}


Write-Host "Reindexing $index to $indexNew" -ForegroundColor Green

Reindex

Function CompareDocumentCounts {

    $oldDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$index" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

    $newDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

    if($oldDocsCount -eq $newDocsCount){
        Write-Host "The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount" -ForegroundColor Green
    }else{
        Write-Host "The document count does not match: $oldDocsCount : $newDocsCount " -ForegroundColor Yellow
        Exit
    }
}

CompareDocumentCounts

Function GetOldIndexAlias {

    $aliases = Invoke-RestMethod -URI "http://$nodeName`:9200/$index/_alias/*" -Method 'GET' -ContentType $contentType  | select -Property $index -ExpandProperty $index | select -Property aliases
    $aliases | gm -type NoteProperty | ForEach-Object {
    $value = $aliases.aliases
    [array]$aliasesArray = ($value | gm | select -Property Name -ExpandProperty Name).Split()
    $readAliasOld = $aliasesArray -like "*read"
    $writeAliasOld = $aliasesArray -like "*write"
    $verifyAliasOld = $aliasesArray -like "*verify"
  }
}

GetOldIndexAlias



Function RemoveAliases {

    $subString = ($index.Substring(0,$index.Length-1))
    Invoke-RestMethod -URI "http://$nodeName`:9200/$subString*/_alias/*" -Method Delete -ContentType $contentType
    Write-Verbose "Removing the Aliases from $index and $indexNew"
}

RemoveAliases

Function GenerateAliases {

    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$readAliasOld" -Method Put -ContentType $contentType 
    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$writeAliasOld" -Method Put -ContentType $contentType
    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$verifyAliasOld" -Method Put -ContentType $contentType
}

GenerateAliases

Function DeleteOldIndex {

    CompareDocumentCounts
    Invoke-RestMethod -URI "http://$nodeName`:9200/$index/" -Method Delete -ContentType $contentType
    Write-Host "The old index: $index has been deleted."
}

DeleteOldIndex