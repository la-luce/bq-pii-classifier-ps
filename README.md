# BigQuery PII Classifier

> [!WARNING]
> **This fork is for new deployments only.**
>
> Starting fresh? You're in the right place. 🌱 We built this fork of
> [GoogleCloudPlatform/bq-pii-classifier](https://github.com/GoogleCloudPlatform/bq-pii-classifier)
> (the *upstream* repository) for teams that haven't deployed the upstream solution yet. Here,
> *new* means new to this solution, not a brand-new environment: it's designed to work with the
> data projects, pipelines, and networks you already have. For details, see
> [What this touches in your environment](#what-this-touches-in-your-environment).
>
> Already running the upstream solution? Keep using the upstream repository. This fork doesn't
> include a migration path, so if you apply its Terraform configuration to an existing upstream
> deployment, Terraform changes or deletes existing resources. For example, it permanently deletes
> the Firestore in Datastore mode database that the upstream solution uses as a cache for its
> `get-policy-tags` function. By default, that's your project's `(default)` database.
>
> Not sure which applies to you? Contact your Google Cloud team before you deploy. We'd much rather
> help you with `terraform plan` than with the cleanup after `terraform apply`.

### Updates

* Cloud Data Loss Prevention (Cloud DLP) is now a part of Sensitive Data Protection. The API name remains the same: Cloud Data Loss Prevention API (DLP API). For information about the services that make up Sensitive Data Protection, see [Sensitive Data Protection overview](https://cloud.google.com/dlp/docs/sensitive-data-protection-overview).
* Automatic DLP (Auto-DLP) is now Sensitive Data Protection discovery service (aka. discovery service).

## Overview

BigQuery PII Classifier is an OSS solution to automate the process of discovering and tagging
PII data across BigQuery tables and applying column-level access controls to restrict 
specific PII data types to certain users/groups in certain domains (e.g. business units)
based on the confidentiality level of that PII.

![alt text](diagrams/summary.png)

Main Steps:

1. *Data Classification Taxonomy and User Access Configuration:*  
   Declare a taxonomy/hierarchy for PII types, and their confidentiality levels which can be modified and extended by customers to allow for custom PII types. 
2. *BigQuery Tables Inspection:*  
   Scan & automatically discover PII data based on the defined data classification taxonomy
3. *Columns Tagging:*  
   Applying access-control tags to columns in accordance with data classification 
4. *Enforcing Column-level Access Control:*  
    Limit PII data access to specific groups based on domains and data classification (e.g. Marketing High Confidentiality PII Readers, Finance Low Confidentiality PII Readers)  
    
<i>If you find this solution helpful please show us your support by <b>starring or forking</b> the repo and 
report issues using the Github tracker.  
If you're a Googler kindly fill in this short [survey](https://docs.google.com/forms/d/19D-3pocKKdDjFuaEoo_XBGoaRVGdbs_DAe35jbKcyyI/viewform)
for tracking and reach out to <b>bq-pii-classifier@</b> for support.</i> 

## Solution Modes
The solution comes with two modes, [standard-mode](docs/guide-standard-dlp.md) and [discovery-service-mode](docs/guide-discovery-service.md).

### Standard Mode

In standard-mode, the solution scope is:
* Automation of DLP inspection for tables (given an array of configurations)
* Applying policy tags to columns based on the PII types detected by the DLP inspection jobs
* Restricting access to the tagged columns based on the confidentiality level
* Possibility to trigger a "re-tagging" run that uses the last inspection results to overwrite the column policy tags.

For more details and on how to use the solution in `standard-mode` follow the [standard-mode guide](docs/guide-standard-dlp.md).

### Discovery Service Mode 

In discovery-service mode, the solution scope is:
* Not managing tables inspection, instead it will build on top of sensitive data discovery service (managed outside of the solution).
* Apply policy tags to columns based on the PII types detected by the discovery service.
* Restricting access to the tagged columns based on the confidentiality level

For more details and on how to use the solution in `discovery-service-mode` follow the [discovery-service-mode guide](docs/guide-discovery-service.md).

### Which mode to use?

Using `standard-mode` offers the following benefits:
* **Granular BigQuery scan scope**. Standard-mode could be configured to include/exclude projects, datasets and tables. Where in sensitive data discovery service, configurations 
are on Organization, folder and project levels. 
* **Control over DLP sampling size**. Standard-mode let you configure the DLP scan sample size as a function of the table size. For example, full scans of smaller tables
and sampling a lower percentage/number of records for bigger tables. This feature let you estimate and control DLP inspection cost to a higher degree.
* **Control over scan schedules**. Standard-mode enables you to call an entry-point service (i.e. Inspection Dispatcher) with different scan scopes on different schedules.
For example, historical dump tables could be scanned once every x month vs daily-refreshed tables could be scanned every x days.
* **On demand scans**. Standard-mode enables you to invoke an entry-point service on-demand. For example, after a data pipeline 
finishes you could trigger a call to scan only the table(s) affected by that pipeline.    

Using `discovery-service-mode` offers the following benefits:
* Relying on scalable, native GCP product for inspection/profiling.
* Relying on sensitive data discovery service heuristics to determine when to trigger a table scan. 
* Visualizing data profiles (i.e. tables, columns, PII types, metrics, etc) from the GCP console (UI).
* Accessing GCP Cloud Support for the product (sensitive data discovery service only, not this custom solution).

## What this touches in your environment

This solution is additive: it doesn't replace anything you already run. The only new thing it
needs is a host project for each environment. From there, it works with the data projects,
pipelines, Sensitive Data Protection setup, and networks you already have.

| Where | What happens |
|-------|--------------|
| **Solution host project** (new and dedicated, one per environment) | Terraform creates the solution here: Cloud Run services, Pub/Sub topics, Cloud Scheduler jobs, a BigQuery dataset, policy tag taxonomies, DLP inspection templates, the `get-policy-tags` function, and a Memorystore for Redis instance. |
| **Your existing VPC network** | You prepare a connector subnet, firewall rules, and network permissions. See [Redis Cache Setup](#redis-cache-setup-do-this-before-running-terraform). |
| **Each data project in scope** | The solution's service accounts get IAM roles, such as BigQuery Data Owner for the Tagger. These grants only add members; they never replace existing bindings. In standard mode, Terraform makes the grants, so its service account needs permission to set IAM policies on each data project. In discovery-service mode, you run a script instead, and Terraform doesn't touch your data projects. |
| **Tables in scope** | The Tagger attaches policy tags to columns that contain PII and adds labels to tables. Your data itself doesn't change. |

Your security team will probably ask for the exact roles. They're listed in
[`prepare_data_projects_for_standard_mode.sh`](scripts/prepare_data_projects_for_standard_mode.sh)
and [`prepare_data_projects_for_auto_dlp_mode.sh`](scripts/prepare_data_projects_for_auto_dlp_mode.sh).

Two things to know before you turn it on:

* **Tagging changes who can read columns. That's the point.** By default, the solution enforces
  access control on its policy tags. Anyone without the Fine-Grained Reader role on a column's
  policy tag can't read that column, and queries that reference it fail with an access-denied
  error, even through views and authorized views. Grant readers with the `iam_mapping` variable
  before you turn on enforcement.
* **Existing policy tags stay put.** The Tagger only changes tags from the taxonomies it created.
  If a column already has a policy tag from another taxonomy, the Tagger keeps it and logs a
  warning.

### If you already use Sensitive Data Protection

If you already run the discovery service, we recommend discovery-service mode. It tags columns
based on your discovery data profiles instead of running its own DLP inspection jobs, so you don't
pay to scan the same tables twice. Your scan configuration needs a few updates, which the
[discovery-service guide](docs/guide-discovery-service.md#configure-discovery-service-on-gcp)
walks through:

* Use the inspection templates that Terraform creates, so every infoType that discovery reports
  maps to a policy tag.
* Save data profile copies to the solution's BigQuery table, and publish Pub/Sub notifications to
  the Tagger topic.
* For organization-level scan configurations, the guide uses the solution host project as the
  service agent container, so discovery charges are billed to that project.

These are changes to your existing discovery setup, so bring its owner in early.

### If you run separate dev, test, and prod environments

Deploy the solution once per environment, each in its own host project:

* Use a separate `.tfvars` file for each environment, scoped to that environment's data projects,
  including its Cortex projects if you have them.
* Keep Terraform state separate. The state bucket name in the
  [setup guide](docs/common-terraform-1-prepare.md) includes the host project ID, so this happens
  automatically.
* Prepare a connector subnet in each environment's network.
* Expect different policy tag IDs in each environment, because each deployment creates its own
  taxonomies.

Then promote configuration changes the way you promote code: dev first, then test, then prod.

### If you already use Cortex Framework

Cortex datasets are regular BigQuery datasets, so the solution treats your Cortex projects like any
other data project. A few tips to keep your pipelines and dashboards happy:

* **Include your Cortex location.** The solution creates policy tags only in the locations that
  you list in `source_data_regions`, so it can't tag tables anywhere else. Scheduled runs skip
  those datasets with only a warning in the logs, which makes this one easy to miss. Add the
  location of your Cortex datasets, such as `"us"` for the US multi-region.
* **Tag where personal data lands first.** Start with your raw and CDC datasets. Policy tags are
  enforced on every query that reads a tagged column, so reporting views built on those tables are
  protected too. Reporting tables are different: they hold their own copy of the data, so keep them
  in scope as well. Use `domain_mapping` to assign each Cortex dataset to a domain, and use
  `datasets_exclude_list` to skip reference datasets with no personal data, such as calendar and
  currency tables.
* **Watch for jobs that rebuild tables.** Rebuilding a table drops any policy tag that isn't part
  of the new definition. Until the next tagging run, anyone who can read the table can read every
  column. In Dataform, incremental actions update tables in place and keep their tags, but
  `type: "table"` actions and full refreshes rebuild the table with `CREATE OR REPLACE`. For those
  tables, declare the tags in the SQLX file with `bigqueryPolicyTags`, and use compilation
  variables so each environment points at its own taxonomy. To attach tags, the Dataform service
  account needs `bigquery.tables.setCategory` on the table and `datacatalog.taxonomies.get` on the
  taxonomy in the solution host project. That's the same pair of permissions the Tagger uses.
* **Give pipelines and dashboards access before you enforce.** Anything that reads a tagged column
  needs Fine-Grained Reader, including `MERGE` statements in your CDC pipelines. Add these
  identities to `iam_mapping` for each domain and classification they read:
  * The service account your Dataform workflows run as: either the Dataform service agent
    (`service-PROJECT_NUMBER@gcp-sa-dataform.iam.gserviceaccount.com`) or your custom service
    account.
  * Any other service accounts that run your Cortex pipelines.
  * BI service accounts, such as the one Looker uses.

  A Google group makes this easier: add the group to `iam_mapping` once, and then manage its
  members without another Terraform run.

  If dashboard users should see masked values instead of errors, look at
  [BigQuery data masking](https://cloud.google.com/bigquery/docs/column-data-masking-intro), which
  you configure outside this solution.
* **Existing Cortex policy tags win.** If your Cortex deployment already applies policy tags (for
  example, through Data Mesh access policies), the Tagger leaves those columns alone. To avoid a
  patchwork, decide which tool owns the tags for each dataset, and exclude the rest from this
  solution's scope.

> [!TIP]
> The `v_log_tag_history` view in the solution's BigQuery dataset records what the Tagger did (or,
> in dry-run mode, would do) to every column. Rows with a `KEEP_EXISTING` or
> `DRY_RUN_KEEP_EXISTING` operation are columns where another tool, such as Cortex, already owns
> the tag. The `new_policy_tag` column has the IDs to paste into `bigqueryPolicyTags`.

### Roll out gradually

A few switches make a slow, safe rollout easy:

| Variable | Effect |
|----------|--------|
| `is_dry_run_tags = "True"` and `is_dry_run_labels = "True"` | The Tagger logs what it would do and changes nothing. |
| `data_catalog_taxonomy_activated_policy_types = []` | Tags are applied, but access isn't restricted. |
| `projects_include_list`, `datasets_include_list`, `datasets_exclude_list`, `tables_exclude_list` | Controls which tables are in scope. Start small. |

We recommend this path:

1. In dev, run in dry-run mode and review the `v_log_tag_history` view.
2. Apply tags without enforcement.
3. Grant readers through `iam_mapping`.
4. Turn on enforcement, and run your pipelines and dashboards end to end. They'll tell you quickly
   if anyone is missing from `iam_mapping`.
5. Promote to test, then prod.

## Redis Cache Setup (do this before running Terraform)

The solution includes a small helper function (`get-policy-tags`) that caches lookups in
**Memorystore for Redis**. Terraform creates the Redis instance for you, but Redis only has a
**private IP address**, so it has to be attached to a VPC network you **already have**. It
also needs a small "bridge" (a *Serverless VPC Access connector*) so the function can reach it.

This section walks you through preparing your existing network so Terraform can do the rest.
It takes about 20–30 minutes.

> **What Terraform creates for you:** the Redis instance (with password and encryption turned on),
> the VPC connector, and a Secret Manager secret that holds the Redis password.
> **What you prepare by hand (once):** the network prerequisites below.

### Step 0: Who needs to do what

Most landing zones keep networking in a separate **host project** managed by a network or platform team.
Some of the steps below must be run by someone with admin rights on that host project.

| Step | What | Who usually runs it |
|------|------|---------------------|
| 1 | Collect network details | You |
| 2 | Turn on APIs in the solution project | You |
| 3 | Check Private Services Access | Network admin (host project) |
| 4 | Create a small subnet for the connector | Network admin (host project) |
| 5 | Grant network permissions | Network admin (host project) |
| 6 | Add firewall rules | Network admin (host project) |
| 7 | Fill in the `.tfvars` file | You |
| 8 | Deploy and verify | You |

> **Tip:** Send steps 3–6 to your network team as-is. Every command is ready to copy and paste
> once the variables in Step 1 are set.

### Step 1: Collect your network details

Open a terminal (or [Cloud Shell](https://shell.cloud.google.com)) and set the variables below.
If you already followed the [environment setup](docs/common-terraform-1-prepare.md), `PROJECT_ID`,
`PROJECT_NUMBER`, `COMPUTE_REGION` and `TF_SA` are already set.

```shell
# The project where this solution is deployed
export PROJECT_ID=<solution project id>
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export COMPUTE_REGION=<region, e.g. us-east4>
export TF_SA=bq-pii-classifier-terraform
```

**Find the host project that owns your network:**

```shell
gcloud compute shared-vpc get-host-project $PROJECT_ID
```

* If this prints a project ID, your landing zone uses **Shared VPC** (most common). Continue with this guide.
* If it prints nothing, the network lives in your own project. Jump to
  [If you do NOT use Shared VPC](#if-you-do-not-use-shared-vpc).

```shell
export HOST_PROJECT_ID=<project id printed above>
```

**Find the network name:**

```shell
gcloud compute networks list --project=$HOST_PROJECT_ID --format="table(name)"
```

```shell
export VPC_NETWORK_NAME=<network name from the list>
```

**Pick a name and an unused IP range for the connector subnet.** It must be a `/28`
(16 addresses) and must not overlap anything that already exists. List the ranges in use:

```shell
# Subnets already in the network
gcloud compute networks subnets list --project=$HOST_PROJECT_ID \
  --network=$VPC_NETWORK_NAME --format="table(name,region,ipCidrRange)"

# Ranges reserved for Google services (Private Services Access)
gcloud compute addresses list --global --project=$HOST_PROJECT_ID \
  --filter="purpose=VPC_PEERING" --format="table(name,address,prefixLength)"
```

Choose a free `/28`. If your landing zone has an IP plan (IPAM), ask the network team for one.

```shell
export CONNECTOR_SUBNET_NAME=bq-pii-connector-subnet
export CONNECTOR_SUBNET_RANGE=<free /28, e.g. 10.10.0.0/28>
```

### Step 2: Turn on the required APIs in the solution project

```shell
gcloud services enable redis.googleapis.com vpcaccess.googleapis.com \
  secretmanager.googleapis.com servicenetworking.googleapis.com \
  --project=$PROJECT_ID

# Make sure the VPC connector's service agent exists (needed in Step 5)
gcloud beta services identity create --service=vpcaccess.googleapis.com --project=$PROJECT_ID
```

### Step 3: Check Private Services Access (network admin)

Redis connects to a Shared VPC through **Private Services Access**. Most landing zones already have it.
Check:

```shell
gcloud services vpc-peerings list --network=$VPC_NETWORK_NAME --project=$HOST_PROJECT_ID
```

* ✅ If you see `servicenetworking.googleapis.com` in the output, it's set up. Go to Step 4.
* ❌ If the output is empty, create it (pick a free `/24` or larger for `PSA_RANGE`):

```shell
export PSA_RANGE_NAME=google-managed-services-range
export PSA_RANGE=<free range, e.g. 10.20.0.0>   # the network address only, no /xx

gcloud compute addresses create $PSA_RANGE_NAME --project=$HOST_PROJECT_ID \
  --global --purpose=VPC_PEERING --addresses=$PSA_RANGE --prefix-length=24 \
  --network=$VPC_NETWORK_NAME

gcloud services vpc-peerings connect --project=$HOST_PROJECT_ID \
  --service=servicenetworking.googleapis.com --ranges=$PSA_RANGE_NAME \
  --network=$VPC_NETWORK_NAME
```

### Step 4: Create the connector subnet (network admin)

```shell
gcloud compute networks subnets create $CONNECTOR_SUBNET_NAME \
  --project=$HOST_PROJECT_ID --network=$VPC_NETWORK_NAME \
  --region=$COMPUTE_REGION --range=$CONNECTOR_SUBNET_RANGE
```

> This subnet must be used **only** by the connector. Don't put VMs or other resources in it.

### Step 5: Grant network permissions (network admin)

The solution project needs permission to use the host project's network. Run all three:

```shell
# Lets the VPC connector attach to the subnet
gcloud projects add-iam-policy-binding $HOST_PROJECT_ID \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-vpcaccess.iam.gserviceaccount.com" \
  --role="roles/compute.networkUser"

# Google APIs service agent of the solution project
gcloud projects add-iam-policy-binding $HOST_PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudservices.gserviceaccount.com" \
  --role="roles/compute.networkUser"

# The Terraform service account, so it can create Redis and the connector on this network
gcloud projects add-iam-policy-binding $HOST_PROJECT_ID \
  --member="serviceAccount:${TF_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/compute.networkUser"
```

> If your security policy doesn't allow project-wide grants, the network team can grant
> `roles/compute.networkUser` on just the connector subnet instead.

### Step 6: Add firewall rules (network admin)

With Shared VPC, Google can't create the connector's firewall rules automatically, so they
must be added to the host project. These rules only apply to connectors (`vpc-connector` tag).

```shell
# Traffic between Google's serverless infrastructure and the connector
gcloud compute firewall-rules create bq-pii-serverless-to-connector \
  --project=$HOST_PROJECT_ID --network=$VPC_NETWORK_NAME \
  --direction=INGRESS --action=ALLOW --rules=tcp:667,udp:665-666,icmp \
  --source-ranges=35.199.224.0/19 --target-tags=vpc-connector

gcloud compute firewall-rules create bq-pii-connector-to-serverless \
  --project=$HOST_PROJECT_ID --network=$VPC_NETWORK_NAME \
  --direction=EGRESS --action=ALLOW --rules=tcp:727,udp:665-666,icmp \
  --destination-ranges=35.199.224.0/19 --target-tags=vpc-connector

# Health checks for the connector
gcloud compute firewall-rules create bq-pii-connector-health-checks \
  --project=$HOST_PROJECT_ID --network=$VPC_NETWORK_NAME \
  --direction=INGRESS --action=ALLOW --rules=tcp:667 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16,108.170.220.0/23 --target-tags=vpc-connector
```

**Only if your landing zone blocks outbound (egress) traffic by default:** also allow the connector
to reach Redis. Redis uses port `6378` because encryption is on. Use the Private Services Access
range from Step 1 / Step 3:

```shell
gcloud compute firewall-rules create bq-pii-connector-to-redis \
  --project=$HOST_PROJECT_ID --network=$VPC_NETWORK_NAME \
  --direction=EGRESS --action=ALLOW --rules=tcp:6378 \
  --destination-ranges=<PSA range, e.g. 10.20.0.0/24> --target-tags=vpc-connector
```

> If your landing zone has "deny" firewall rules or hierarchical firewall policies, these allow
> rules need a **lower priority number** than the deny rules (for example `--priority=900`).
> Your network team will know.

### Step 7: Fill in your `.tfvars` file

Add these lines to the `.tfvars` file you use for deployment
(see [Terraform variables](docs/common-terraform-2-variables.md)):

```hcl
# Existing Shared VPC network (from Step 1)
vpc_network_name    = "<VPC_NETWORK_NAME>"
vpc_network_project = "<HOST_PROJECT_ID>"

# Connector subnet you created in Step 4
vpc_connector_subnet_name = "<CONNECTOR_SUBNET_NAME>"

# Required for Shared VPC
redis_connect_mode = "PRIVATE_SERVICE_ACCESS"

# Optional: "STANDARD_HA" for a highly available (and more expensive) Redis. Default is "BASIC".
# redis_tier = "BASIC"
```

Tip: print the exact values you set earlier with:

```shell
echo "vpc_network_name = \"$VPC_NETWORK_NAME\""; echo "vpc_network_project = \"$HOST_PROJECT_ID\""; \
echo "vpc_connector_subnet_name = \"$CONNECTOR_SUBNET_NAME\""; echo 'redis_connect_mode = "PRIVATE_SERVICE_ACCESS"'
```

### Step 8: Deploy and verify

Continue with your deployment guide ([standard mode](docs/guide-standard-dlp.md) or
[discovery-service mode](docs/guide-discovery-service.md)) and run Terraform as usual.
Creating Redis takes about 5–10 minutes.

When Terraform finishes, check that everything is healthy:

```shell
# Redis should be READY
gcloud redis instances describe policy-tags-cache --region=$COMPUTE_REGION \
  --project=$PROJECT_ID --format="value(state,host,port)"

# Connector should be READY
gcloud compute networks vpc-access connectors describe policy-tags-connector \
  --region=$COMPUTE_REGION --project=$PROJECT_ID --format="value(state)"

# No Redis warnings from the function in the last hour (empty output = good)
gcloud logging read '"Redis cache" AND severity>=WARNING' \
  --project=$PROJECT_ID --freshness=1h --limit=10
```

> The function keeps working even if Redis can't be reached; it just skips the cache and logs a
> warning. So if you see `Redis cache GET failed` warnings, the solution still works, but check
> the troubleshooting table below.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Terraform: `Required 'compute.subnetworks.use' permission` | Step 5 not done | Run the Step 5 grants in the host project |
| Terraform: connector stuck creating / `ERROR` | Firewall rules missing or subnet not `/28` | Re-check Step 4 and Step 6 |
| Terraform: Redis error about private services access / `connect_mode` | PSA missing, or `redis_connect_mode` not set | Re-check Step 3 and Step 7 |
| Terraform: IP range overlap | Connector subnet overlaps an existing range | Pick another free `/28` in Step 1 |
| Logs: `Redis cache GET failed ... timed out` | Egress to Redis blocked | Add the `bq-pii-connector-to-redis` rule in Step 6 |
| Terraform: `Unsupported Terraform Core version` | Terraform too old | Install Terraform `1.12.1` or newer |

### If you do NOT use Shared VPC

If the network lives in the same project as the solution, setup is much simpler: Terraform
creates the connector and its firewall rules for you.

1. Run Step 2 (APIs).
2. Pick a free `/28` range (see Step 1; use `$PROJECT_ID` instead of `$HOST_PROJECT_ID`).
3. If outbound traffic is blocked by default, add the `bq-pii-connector-to-redis` rule from Step 6
   (in your project). After deployment, find the Redis range with
   `gcloud redis instances describe policy-tags-cache --region=$COMPUTE_REGION --format="value(reservedIpRange)"`.
4. Add to your `.tfvars`:

```hcl
vpc_network_name            = "<network name>"
vpc_connector_ip_cidr_range = "<free /28, e.g. 10.10.0.0/28>"
# redis_connect_mode defaults to "DIRECT_PEERING", which is correct here
```

## Cost Control
The main contributing components to cost in this solution are DLP Inspection Jobs and BigQuery
Analytical Usage, where each component has its own cost control measures.

<b>For DLP:</b>  
    You can set the number or percentage of rows to be randomly selected 
and inspected from each table as a function of the table size. This is done in the Terraform
configuration as part of the deployment procedures. Please note that setting is only applicable
in the `standard-mode` while in `discovery-service-mode` it's up to the discovery service configurations and heuristics
to determine the frequency and number of rows to scan from each table.


<b>For BigQuery:</b>  
    It's important to understand that the solution (more specifically, the Tagger service)
will submit one query per target table in order to fetch its DLP findings,
interpret it and apply policy tags to that table. This query runs against a common DLP detailed
findings table that can grow large very quickly in runs that includes a large number of tables.
This in turn translates to more bytes scanned that contribute to higher costs.  

In order to factor in this point, it's highly advised to do one or more of the following if 
you plan to scan a large number of tables:
* Assign the solution host project to a BigQuery [Slot Reservation](https://cloud.google.com/bigquery/docs/reservations-intro) (Flat-Rate pricing)
* Create BigQuery [Custom Cost Controls](https://cloud.google.com/bigquery/docs/custom-quotas) to avoid scanning (and paying) more than a daily Threshold 

## Data Access Model Example
 
  Check out this [document](docs/common-iam-example.md) for an example on a data access
  model across domains and IAM group structure.

 ## Solution Limits
  
 Check out this [document](docs/common-limits.md) for solution limits.
 
 ## GCP Quotas
 
 Check out this [document](docs/common-quotas.md) for related GCP Quotas.