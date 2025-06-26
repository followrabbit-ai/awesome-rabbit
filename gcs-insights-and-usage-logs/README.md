# Rabbit Storage Insights and Usage Logs Terraform Module

Rabbit is capable of providing deep folder or object level insights and storage class recommendations with automated class management based on the access patterns. In order to do this, we need to enable Storage Insights and Usage Logs on the target buckets.
This Terraform module is designed to configure Google Cloud Storage Insights and Usage Logs for specified target buckets. It automates the setup of necessary resources, including report buckets, IAM roles, and report configurations.

## Features

- Creates report buckets for storing insights and usage log data.
- Configures IAM roles for storage insights and usage logging.
- Sets up Storage Insights report configurations for target buckets.
- Enables usage logging for the specified buckets.

## Prerequisites

- Google Cloud project with appropriate permissions.
- Terraform installed on your local machine.
- `gcloud` CLI installed and authenticated.

## Usage

### Variables

Change the following variables:

- **`project_id`**: The GCP project ID where the APIs can be called.

- **`target_buckets`**: A list of bucket names for which storage insights and usage logs will be enabled.

### Example

```hcl
module "storage_insights" {
  source = "./scripts/storage-insights"

  project_id     = "your-project-id"
  target_buckets = ["your-bucket-1", "your-bucket-2"]
}
```

## Resources Created

The module creates the following resources:

1. **Google Storage Buckets for the report files**:
   Report buckets for storing insights and usage data with a lifecycle rule to delete objects older than 10 days.

2. **IAM Roles**:
    - `roles/storage.objectCreator` for the Storage Insights service account.
    - `roles/storage.insightsCollectorService` for the target buckets.

3. **Storage Insights Report Configurations**:
   Weekly reports in parquet format.

4. **Usage Logging**:
   Configures usage logging for the target buckets.

## Files

- **`provider.tf`**: Configures the Google Cloud provider.
- **`report_bucket.tf`**: Creates report buckets and lifecycle rules.
- **`storage_insights.tf`**: Configures Storage Insights and IAM roles.
- **`usage_logs.tf`**: Enables usage logging for the target buckets.
- **`variables.tf`**: Defines input variables for the module.

## How to Run

1. Initialize Terraform:
   ```bash
   terraform init
   ```

2. Plan the changes:
   ```bash
   terraform plan
   ```

3. Apply the changes:
   ```bash
   terraform apply
   ```

## Notes

- Ensure that the `project_id` variable matches your GCP project.
- The `target_buckets` variable should include the names of the buckets you want to enable insights for.
- If you are already managing your bucket through Terraform, you can turn on the usage logs there or specify lifecycle rules to avoid conflicting changes.
- The module uses the `google-beta` provider for some resources.

## License

This module is licensed under the MIT License.
