# /*
# * Copyright 2023 Google LLC
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# *     https://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# */

resource "random_id" "run_id" {
  byte_length = 8
  keepers = {
    # this will ensure the function gets redeployed only when the code changes
    timestamp = timestamp()
  }
}

##### Memorystore for Redis is used by the function as a cache layer

locals {
  vpc_network_project = coalesce(var.vpc_network_project, var.project)
  vpc_network_id      = "projects/${local.vpc_network_project}/global/networks/${var.vpc_network_name}"
}

resource "google_project_service" "redis_api" {
  project            = var.project
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "vpcaccess_api" {
  project            = var.project
  service            = "vpcaccess.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager_api" {
  project            = var.project
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_redis_instance" "cache" {
  project                 = var.project
  name                    = var.redis_instance_name
  region                  = var.compute_region # same region as the cloud function
  tier                    = var.redis_tier
  memory_size_gb          = var.redis_memory_size_gb
  redis_version           = var.redis_version
  authorized_network      = local.vpc_network_id
  connect_mode            = var.redis_connect_mode
  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  # all keys are written with a TTL; evict least recently used keys if memory is full
  redis_configs = {
    maxmemory-policy = "volatile-lru"
  }

  depends_on = [google_project_service.redis_api]
}

# Serverless VPC Access connector so the function can reach the Redis private IP
resource "google_vpc_access_connector" "connector" {
  project       = var.project
  name          = var.vpc_connector_name
  region        = var.compute_region # same region as the cloud function
  machine_type  = var.vpc_connector_machine_type
  min_instances = var.vpc_connector_min_instances
  max_instances = var.vpc_connector_max_instances

  # Either create the connector on a new /28 range in the network, or on an existing dedicated /28 subnet
  network       = var.vpc_connector_subnet_name == null ? var.vpc_network_name : null
  ip_cidr_range = var.vpc_connector_subnet_name == null ? var.vpc_connector_ip_cidr_range : null

  dynamic "subnet" {
    for_each = var.vpc_connector_subnet_name == null ? [] : [1]
    content {
      name       = var.vpc_connector_subnet_name
      project_id = local.vpc_network_project
    }
  }

  depends_on = [google_project_service.vpcaccess_api]
}

# Redis AUTH string is exposed to the function via Secret Manager rather than a plain env variable
resource "google_secret_manager_secret" "redis_auth" {
  project   = var.project
  secret_id = "${var.redis_instance_name}-auth"

  replication {
    user_managed {
      replicas {
        location = var.compute_region
      }
    }
  }

  depends_on = [google_project_service.secretmanager_api]
}

resource "google_secret_manager_secret_version" "redis_auth" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.cache.auth_string
}

##### BigQuery Connection

resource "google_bigquery_connection" "connection" {
  connection_id = var.function_name
  project       = var.project
  location      = var.data_region # same region as the cloud function

  ## Note: The cloud resource nested object has only one output only field - serviceAccountId.
  cloud_resource {}
}

##### Cloud Function SA #################################

resource "google_service_account" "sa_function" {
  project      = var.project
  account_id   = var.service_account_name
  display_name = "Runtime SA for Cloud Function ${var.function_name}"
}

# Permissions needed for the cloud function SA
resource "google_project_iam_member" "sa_function_roles" {
  project  = var.project
  for_each = toset(concat([
    "roles/logging.logWriter",
    "roles/artifactregistry.reader"
  ],
    var.cloud_functions_sa_extra_roles
  ))
  role   = each.key
  member = "serviceAccount:${google_service_account.sa_function.email}"
}

# Allow the function SA to read the Redis AUTH string
resource "google_secret_manager_secret_iam_member" "sa_function_redis_auth" {
  project   = var.project
  secret_id = google_secret_manager_secret.redis_auth.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sa_function.email}"
}

#####################################################

resource "google_storage_bucket" "resources_bucket" {
  name                        = "${var.project}-cf-${var.function_name}-resources"
  location                    = var.compute_region # same region as the cloud function
  force_destroy               = true
  uniform_bucket_level_access = true
}

# Generates an archive of the source code compressed as a .zip file.
data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.cloud_function_src_dir
  output_path = var.cloud_function_temp_dir
}

# Add source code zip to the Cloud Function's bucket
resource "google_storage_bucket_object" "zip" {
  source       = data.archive_file.source.output_path
  content_type = "application/zip"

  # Append to the MD5 checksum of the files' content
  # to force the zip to be updated as soon as a change occurs
  name   = "src-${data.archive_file.source.output_md5}.zip"
  bucket = google_storage_bucket.resources_bucket.name
}

resource "google_cloudfunctions2_function" "function" {
  name     = var.function_name
  project  = var.project
  location = var.compute_region # same region as the cloud function

  build_config {
    runtime     = "python310"
    entry_point = var.function_entry_point  # Set the entry point
    source {
      storage_source {
        bucket = google_storage_bucket.resources_bucket.name
        object = google_storage_bucket_object.zip.name
      }
    }
  }

  service_config {
    max_instance_count               = var.cf_max_instance_count
    min_instance_count               = var.cf_min_instance_count
    available_memory                 = var.cf_available_memory
    timeout_seconds                  = var.cf_timeout_seconds
    max_instance_request_concurrency = var.cf_max_instance_request_concurrency
    available_cpu                    = var.cf_available_cpu
    environment_variables = merge(var.env_variables, {
      TERRAFORM_RUN_ID  = random_id.run_id.hex # to force TF to deploy the function on each run
      REDIS_HOST        = google_redis_instance.cache.host
      REDIS_PORT        = tostring(google_redis_instance.cache.port)
      REDIS_CA_CERT     = join("\n", [for c in google_redis_instance.cache.server_ca_certs : c.cert])
      CACHE_TTL_SECONDS = tostring(var.cache_ttl_seconds)
    })
    secret_environment_variables {
      key        = "REDIS_AUTH"
      project_id = var.project
      secret     = google_secret_manager_secret.redis_auth.secret_id
      version    = "latest"
    }
    vpc_connector                  = google_vpc_access_connector.connector.id
    vpc_connector_egress_settings  = "PRIVATE_RANGES_ONLY"
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true
    service_account_email          = google_service_account.sa_function.email
  }

  depends_on = [
    google_secret_manager_secret_version.redis_auth,
    google_secret_manager_secret_iam_member.sa_function_redis_auth,
  ]
}



resource "google_cloud_run_service_iam_member" "sa_invoker" {
  project  = var.project
  location = var.compute_region # same region as the cloud function
  service  = google_cloudfunctions2_function.function.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_bigquery_connection.connection.cloud_resource[0].service_account_id}"

  depends_on = [google_bigquery_connection.connection, google_cloudfunctions2_function.function]
}

#########

# create a stored procedure that deploys the function and call it from outside Terraform

resource "google_bigquery_routine" "routine_deploy_functions" {
  dataset_id      = var.bigquery_dataset_name
  routine_id      = "deploy_${var.function_name}"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = templatefile(var.deployment_procedure_path,
    {
      project            = var.project
      dataset            = var.bigquery_dataset_name
      function_name      = "remote_${var.function_name}"
      connection_region  = google_bigquery_connection.connection.location
      connection_name    = google_bigquery_connection.connection.connection_id
      cloud_function_url = google_cloudfunctions2_function.function.service_config[0].uri
    }
  )
}


## Run a BQ job to deploy the remote functions
resource "google_bigquery_job" "deploy_remote_functions_job" {
  job_id   = "d_job_${google_bigquery_routine.routine_deploy_functions.routine_id}_${random_id.run_id.hex}"
  location = var.data_region # same as dataset used by the solution

  query {
    priority = "INTERACTIVE"
    query    = "CALL ${var.bigquery_dataset_name}.${google_bigquery_routine.routine_deploy_functions.routine_id}();"
    create_disposition = "" # must be set to "" for scripts
    write_disposition = ""  # must be set to "" for scripts
  }
}