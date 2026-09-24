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

variable "service_account_name" {
  type = string
}

variable "project" {
  type = string
}

variable "compute_region" {
  type = string
}

variable "data_region" {
  type = string
}

variable "function_name" {
  type = string
}

variable "cloud_function_src_dir" {
  type = string
}

variable "cloud_function_temp_dir" {
  type = string
}

variable "function_entry_point" {
  type = string
}

variable "env_variables" {
  type = map(string)
}

variable "bigquery_dataset_name" {
  type = string
}

variable "deployment_procedure_path" {
  type = string
}

variable "cloud_functions_sa_extra_roles" { type = list(string) }

variable "cf_max_instance_count" {
  type = number
  default = 3
}

variable "cf_min_instance_count" {
  type = number
  default = 1
}

variable "cf_available_memory" {
  type = string
  default = "1Gi"
}

variable "cf_timeout_seconds" {
  type = number
  default = 3600
}

variable "cf_max_instance_request_concurrency" {
  type = number
  default = 80
}

variable "cf_available_cpu" {
  type    = string
  default = "2"
}

##### Networking (Redis is only reachable over a private IP in this VPC)

variable "vpc_network_name" {
  description = "Name of the existing VPC network that Redis is attached to and the VPC connector is created in"
  type        = string
}

variable "vpc_network_project" {
  description = "Project hosting the VPC network (e.g. Shared VPC host project). Defaults to var.project"
  type        = string
  default     = null
}

variable "vpc_connector_name" {
  description = "Name of the Serverless VPC Access connector (max 25 chars, lowercase letters, digits and hyphens)"
  type        = string
  default     = "policy-tags-connector"
}

variable "vpc_connector_ip_cidr_range" {
  description = "Unused /28 range in the VPC for the connector. Ignored if vpc_connector_subnet_name is set"
  type        = string
  default     = "10.8.0.0/28"
}

variable "vpc_connector_subnet_name" {
  description = "Optional existing dedicated /28 subnet for the connector (required for Shared VPC). Takes precedence over vpc_connector_ip_cidr_range"
  type        = string
  default     = null
}

variable "vpc_connector_machine_type" {
  type    = string
  default = "e2-micro"
}

variable "vpc_connector_min_instances" {
  type    = number
  default = 2
}

variable "vpc_connector_max_instances" {
  type    = number
  default = 3
}

##### Memorystore for Redis cache

variable "redis_instance_name" {
  description = "Name of the Memorystore for Redis instance (lowercase letters, digits and hyphens)"
  type        = string
  default     = "policy-tags-cache"
}

variable "redis_tier" {
  description = "BASIC or STANDARD_HA"
  type        = string
  default     = "BASIC"
}

variable "redis_memory_size_gb" {
  type    = number
  default = 1
}

variable "redis_version" {
  type    = string
  default = "REDIS_7_0"
}

variable "redis_connect_mode" {
  description = "DIRECT_PEERING, or PRIVATE_SERVICE_ACCESS (required for Shared VPC; needs private services access configured on the network)"
  type        = string
  default     = "DIRECT_PEERING"
}

variable "cache_ttl_seconds" {
  description = "How long policy tag display names are cached in Redis"
  type        = number
  default     = 3600
}