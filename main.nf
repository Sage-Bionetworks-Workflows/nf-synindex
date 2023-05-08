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
  if (base_key != '/') {
    s3_prefix = "s3://${bucket_name}/${base_key}"  // Ensuring common format
  } else {
    s3_prefix = "s3://${bucket_name}"  // Ensuring common format
  }
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

  output:
    stdout

  script:
  """
  get_user_id.py
  """

}


process update_owner {
  debug true
  label 'aws'
  // secret 'AWS_ACCESS_KEY_ID'
  // secret 'AWS_SECRET_ACCESS_KEY'
  // secret 'AWS_SESSION_TOKEN'
  secret 'SC_SYNAPSE_AUTH_TOKEN'

  input:
    val user_id
    val s3_prefix

  output:
    val true

  script:
  """
  mkdir /root/.aws
  echo "[profile service-catalog]" > /root/.aws/config
  echo "region=us-east-1" >> /root/.aws/config
  echo "credential_process = '/root/synapse_creds.sh' 'https://sc.sageit.org' '\$SC_SYNAPSE_AUTH_TOKEN'" >> /root/.aws/config

  ( \
     ( aws s3 --profile service-catalog cp ${s3_prefix}/owner.txt - 2>/dev/null || true ); \
      echo $user_id \
  ) \
  | sort -u \
  | aws s3 --profile service-catalog cp - ${s3_prefix}/owner.txt
  """

}


process register_bucket {
  
  label 'synapse'

  secret 'SYNAPSE_AUTH_TOKEN'

  input:
    val bucket
    val base_key
    val flag

  output:
    stdout

  script:
  """
  register_bucket.py \
  --bucket ${bucket} \
  --base_key ${base_key}
  """

}


process list_objects {

  label 'aws'
  // secret 'AWS_ACCESS_KEY_ID'
  // secret 'AWS_SECRET_ACCESS_KEY'
  // secret 'AWS_SESSION_TOKEN'
  secret 'SC_SYNAPSE_AUTH_TOKEN'

  input:
    val s3_prefix
    val bucket

  output:
    path 'objects.txt'

  script:
  """
  mkdir /root/.aws
  echo "[profile service-catalog]" > /root/.aws/config
  echo "region=us-east-1" >> /root/.aws/config
  echo "credential_process = '/root/synapse_creds.sh' 'https://sc.sageit.org' '\$SC_SYNAPSE_AUTH_TOKEN'" >> /root/.aws/config

  aws s3 --profile service-catalog ls ${s3_prefix} --recursive \
  | grep -v -e '/\$' -e 'synindex/under-' -e 'owner.txt\$' \
    -e 'synapseConfig' -e 'synapse_config' \
  | awk '{\$1=\$2=\$3=""; print \$0}' \
  | sed 's|^   |s3://${bucket}/|' \
  > objects.txt
  """

}


process synapse_mirror {
  debug true
  label 'synapse'

  secret 'SYNAPSE_AUTH_TOKEN'

  // Comment out publish dir for right now
  // publishDir publish_dir, mode: 'copy'

  input:
    path  objects
    val   s3_prefix
    val   parent_id

  output:
    path 'parent_ids.csv'

  script:
  """
  synmirror.py \
  --objects ${objects} \
  --s3_prefix ${s3_prefix} \
  --parent_id ${parent_id} \
  > parent_ids.csv
  """

}

process synapse_index {
  
  label 'synapse'

  secret 'SYNAPSE_AUTH_TOKEN'

  input:
  tuple val(uri), file(object), val(parent_id)
  val storage_id

  output:
    stdout

  script:
  """
  synindex.py \
  --storage_id ${storage_id} \
  --file ${object} \
  --uri '${uri}' \
  --parent_id ${parent_id}
  """

}


workflow {
  get_user_id()
  update_owner(get_user_id.out, s3_prefix)
  register_bucket(bucket_name, base_key, update_owner.out)
  list_objects(s3_prefix, bucket_name)
  synapse_mirror(list_objects.out, s3_prefix, params.parent_id)

  // Parse list of object URIs and their Synapse parents
  synapse_mirror.out
    .splitCsv()
    .map { row -> [ row[0], file(row[0]), row[1] ] }
    .set { ch_parent_ids }
  synapse_index(ch_parent_ids, register_bucket.out)

  // synapse_index.out.view()
  // //  .collectFile(name: "file_ids.csv", storeDir: publish_dir, newLine: true)

}