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