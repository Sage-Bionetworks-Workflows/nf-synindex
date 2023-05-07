#!/usr/bin/env nextflow


/*
========================================================================================
    SETUP PARAMS
========================================================================================
*/

// Ensure DSL2
nextflow.enable.dsl = 2

// Default values
params.s3_prefix = false
params.parent_id = false
params.synapse_config = false

if ( !params.s3_prefix ) {
  exit 1, "Parameter 'params.s3_prefix' is required!\n"
}

if ( !params.parent_id ) {
  exit 1, "Parameter 'params.parent_id' is required!\n"
}

matches = ( params.s3_prefix =~ '^s3://([^/]+)(?:/+([^/]+(?:/+[^/]+)*)/*)?$' ).findAll()

if ( matches.size() == 0 ) {
  exit 1, "Parameter 'params.s3_prefix' must be an S3 URI (e.g., 's3://bucket-name/some/prefix/')!\n"
} else {
  bucket_name = matches[0][1]
  base_key = matches[0][2]
  base_key = base_key ?: '/'
  s3_prefix = "s3://${bucket_name}/${base_key}"  // Ensuring common format
}

if ( !params.parent_id ==~ 'syn[0-9]+' ) {
  exit 1, "Parameter 'params.parent_id' must be the Synapse ID of a folder (e.g., 'syn98765432')!\n"
}

ch_synapse_config = params.synapse_config ? Channel.value( file(params.synapse_config) ) : "null"

publish_dir = "${s3_prefix}/synindex/under-${params.parent_id}/"


/*
========================================================================================
    SETUP PROCESSES
========================================================================================
*/

process get_user_id {
  
  label 'synapse'

  cache false

  secret 'SYNAPSE_AUTH_TOKEN'

  afterScript "rm -f ${syn_config}"

  input:
    path syn_config

  output:
    stdout

  script:
  config_cli_arg = params.synapse_config ? "--config ${syn_config}" : ""
  """
  get_user_id.py \
  ${config_cli_arg}
  """

}


process update_owner {
  
  label 'aws'

  input:
    val user_id
    val s3_prefix

  output:
    val true

  script:
  """
  ( \
     ( aws s3 cp ${s3_prefix}/owner.txt - 2>/dev/null || true ); \
      echo $user_id \
  ) \
  | sort -u \
  | aws s3 cp - ${s3_prefix}/owner.txt
  """

}


process register_bucket {
  
  label 'synapse'

  secret 'SYNAPSE_AUTH_TOKEN'

  afterScript "rm -f ${syn_config}"

  input:
    val bucket
    val base_key
    path syn_config
    val flag

  output:
    stdout ch_storage_id

  script:
  config_cli_arg = params.synapse_config ? "--config ${syn_config}" : ""
  """
  register_bucket.py \
  --bucket ${bucket} \
  --base_key ${base_key} \
  ${config_cli_arg}
  """

}


process list_objects {

  label 'aws'

  input:
    val s3_prefix
    val bucket

  output:
    path 'objects.txt'

  script:
  """
  aws s3 ls ${s3_prefix}/ --recursive \
  | grep -v -e '/\$' -e 'synindex/under-' -e 'owner.txt\$' \
    -e 'synapseConfig' -e 'synapse_config' \
  | awk '{\$1=\$2=\$3=""; print \$0}' \
  | sed 's|^   |s3://${bucket}/|' \
  > objects.txt
  """
  
}


process synapse_mirror {
  
  label 'synapse'

  secret 'SYNAPSE_AUTH_TOKEN'

  afterScript "rm -f ${syn_config}"

  publishDir publish_dir, mode: 'copy'

  input:
    path  objects    from ch_objects
    val   s3_prefix  from s3_prefix
    val   parent_id  from params.parent_id
    file  syn_config from ch_synapse_config

  output:
    path 'parent_ids.csv'

  script:
  config_cli_arg = params.synapse_config ? "--config ${syn_config}" : ""
  """
  synmirror.py \
  --objects ${objects} \
  --s3_prefix ${s3_prefix} \
  --parent_id ${parent_id} \
  ${config_cli_arg} \
  > parent_ids.csv
  """

}

process synapse_index {
  
  label 'synapse'

  secret 'SYNAPSE_AUTH_TOKEN'

  afterScript "rm -f ${syn_config}"

  input:
  tuple val(uri), file(object), val(parent_id)
  val storage_id
  path syn_config

  output:
    stdout

  script:
  config_cli_arg = params.synapse_config ? "--config ${syn_config}" : ""
  """
  synindex.py \
  --storage_id ${storage_id} \
  --file ${object} \
  --uri '${uri}' \
  --parent_id ${parent_id} \
  ${config_cli_arg}
  """

}


workflow {
  get_user_id(ch_synapse_config)
  update_owner(get_user_id.out, s3_prefix)
  register_bucket(bucket_name, base_key, ch_synapse_config, update_owner.out)
  list_objects(s3_prefix, bucket_name)
  synapse_mirror(ch_objects, s3_prefix, params.parent_id, ch_synapse_config)

  // Parse list of object URIs and their Synapse parents
  synapse_mirror.out
    .text
    .splitCsv()
    .map { row -> [ row[0], file(row[0]), row[1] ] }
    .set { ch_parent_ids }
  synapse_index(ch_parent_ids, ch_storage_id, ch_synapse_config)

  synapse_index
    .collectFile(name: "file_ids.csv", storeDir: publish_dir, newLine: true)

}