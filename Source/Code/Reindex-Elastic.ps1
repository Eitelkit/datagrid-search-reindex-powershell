#Data Grid Reindex Script#

param(
$nodeName = "cs-mv1-caw",
$caseArtifactID = "edds1076732",
$prefix = "audit",
[int]$newShardCount = '2',
[int]$numberOfReplicas = '1',
[bool]$shieldState = $false
)

$contentType = 'application/json'

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

Function NewIndexName {

    $indexStringArray = $index.ToCharArray()
    [int]$short = $indexStringArray.Length - 1
    [int]$lastDigit = [convert]::ToInt32($indexStringArray.GetValue($short), 10)
    [int]$lastPlusOne = $lastDigit + 1
    [string]$lastString = $lastPlusOne
    [char]$lastChar = $lastString
    
    $script:indexNew = $index.Substring(0,$index.Length-1) + $lastString
    
}

Function CreateNewIndex {

    Try{
        Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew" -Method 'PUT' -ContentType $contentType -Body "{ ""settings"": { ""index"":{ ""number_of_shards"": $newShardCount, ""number_of_replicas"": $numberOfReplicas }}}"
    }
    Catch [System.Net.WebException] {
       Write-Host "Could not connect to elastic at $nodeName." -ForegroundColor Red;
    }

}

Function GetMappingsOldIndex {
    (Invoke-RestMethod -URI "http://$nodeName`:9200/$index/_mappings" -Method 'GET' -ContentType $contentType -OutFile c:\json.txt)

    $mappings = (Get-Content C:\json.txt).ToString()

    $mappings = $mappings -replace "{`"$index`":{`"mappings`":"

    $script:mappings = $mappings.Substring(0,$mappings.Length-2) 
}

Function ApplyMappingsToNewIndex {

    Try{
        Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_mapping/$prefix" -Method 'PUT' -ContentType $contentType -Body $mappings
    }
    Catch [System.Net.WebException] {}
}

Function Reindex {
    Try {
    Invoke-RestMethod -Uri "http://$nodeName`:9200/_reindex" -Method Post -ContentType $contentType -Body "{ ""source"": { ""index"": ""$index"" }, ""dest"": { ""index"": ""$indexNew"" }}" -ErrorAction SilentlyContinue
    }
    Catch [System.Net.WebException] {}
}

Function GetDocumentCountOldIndex {

    $script:oldDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$index" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

}

Function CompareDocumentCounts {

    $script:newDocsCount = Invoke-RestMethod -Uri "http://$nodeName`:9200/_cat/indices?v&index=$indexNew" -Method Get -ContentType $contentType | select -Property syncRoot -ExpandProperty syncRoot | select -Property docs.count -ExpandProperty docs.count

    if($oldDocsCount -eq $newDocsCount){
        Write-Host "The document count matches for the old and new indexes: $oldDocsCount : $newDocsCount" -ForegroundColor Green
    }else{
        Write-Host "Reindexing Documents from $index to $indexNew : " (($newDocsCount/$oldDocsCount)*100) "% Complete" -ForegroundColor Yellow
    }
}

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

Function WaitForComplete {
    Do {
    cls
    CompareDocumentCounts
    Sleep -Seconds 10
    } Until ($newDocsCount -eq $oldDocsCount)
}

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

Function RemoveAliases {

    $subString = ($index.Substring(0,$index.Length-1))
    Invoke-RestMethod -URI "http://$nodeName`:9200/$subString*/_alias/*" -Method Delete -ContentType $contentType
    Write-Verbose "Removing the Aliases from $index and $indexNew"
}

Function GenerateAliases {

    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$readAliasOld" -Method Put -ContentType $contentType 
    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$writeAliasOld" -Method Put -ContentType $contentType
    Invoke-RestMethod -URI "http://$nodeName`:9200/$indexNew/_alias/$verifyAliasOld" -Method Put -ContentType $contentType
}

Function DeleteOldIndex {

    CompareDocumentCounts
    Invoke-RestMethod -URI "http://$nodeName`:9200/$index/" -Method Delete -ContentType $contentType
    Write-Host "The old index: $index has been deleted."
}

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