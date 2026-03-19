# Remote Builds on GitHub and AWS

This repository now has three manual build paths for repeated kernel bring-up work:

- `Build on GitHub ARM`
  - Runs directly on GitHub-hosted `ubuntu-24.04-arm`.
  - Best zero-infrastructure option.
  - Good baseline because this public repository gets free standard GitHub-hosted ARM runners.
  - Uses a Nix `post-build-hook` to push completed derivations into an S3-backed Nix binary cache as they finish.
  - Pushes the final result path again at the end for completeness.

- `Build on EC2 Spot ARM`
  - Uses a normal GitHub-hosted runner only as a control plane.
  - Assumes an AWS role over GitHub OIDC.
  - Launches an ephemeral Graviton Spot instance in AWS.
  - Executes the build on that instance over AWS Systems Manager Run Command.
  - Uses the same incremental `post-build-hook` S3 cache push during the build.
  - Terminates the instance after the build unless you ask to keep it.

- `Build on EC2 Fleet ARM`
  - Same control-plane model as the Spot workflow.
  - Uses EC2 Fleet with the Spot `price-capacity-optimized` strategy.
  - Offers multiple Graviton instance types to AWS at once instead of trying them sequentially.
  - Better when Spot capacity is inconsistent and you want AWS to choose the best pool.
  - Uses the same incremental `post-build-hook` S3 cache push during the build.

## Why this design

This repository is public. GitHub's own guidance is that self-hosted runners should almost never be used for public repositories, because workflow code from pull requests can compromise the runner environment.

Instead of registering a private self-hosted runner in GitHub, the fast path here is:

1. GitHub-hosted runner starts the job.
2. GitHub OIDC assumes an AWS role with short-lived credentials.
3. A temporary ARM EC2 instance is launched.
4. The build is run over SSM.
5. The instance is terminated.

This keeps GitHub runner administration out of the design entirely:

- no runner registration token
- no long-lived private runner
- no GitHub self-hosted runner exposed to a public repository

## Cost and performance guidance

- Cheapest:
  - `Build on GitHub ARM`
  - Public GitHub repositories get free standard ARM runners, but they are only 4 vCPU / 16 GiB.

- Faster:
  - `Build on EC2 Spot ARM`
  - Current default region is `eu-west-3`, which had the best sampled `c7g.4xlarge` Spot price during setup.
  - Prefer compute-optimized Graviton families first, then general-purpose fallback.

- More launch-resilient:
  - `Build on EC2 Fleet ARM`
  - AWS can choose among multiple Spot pools using `price-capacity-optimized`.
  - Better than manual fallback when one preferred type is frequently unavailable.

- Region choice:
  - The cache bucket is named `nix-cache-vim1s-<region>`.
  - The current bucket is `nix-cache-vim1s-eu-west-3`.
  - Keep the bucket in the same region as the builder whenever you create another regional cache, or S3 transfer latency will erase most of the benefit.

- Spot guidance:
  - AWS recommends flexibility across instance types and Availability Zones, Spot placement scores, and price-capacity-optimized allocation.
  - This first version keeps the workflow simple and uses an ordered list of preferred Graviton types in one region.
  - If you want the full AWS best-practice path later, extend this to EC2 Fleet or Auto Scaling with price-capacity-optimized allocation.

- Cache behavior:
  - Successful derivations are pushed to the S3 binary cache during the build via a Nix `post-build-hook`.
  - This means failed kernel iterations still populate the cache with completed dependencies and intermediate derivations.
  - The final workflow step still pushes the top-level result path after a successful build.

## Required GitHub configuration

Repository variables:

- `AWS_REGION`
  - Example: `eu-west-3`
- `AWS_SUBNET_ID`
  - Subnet for the builder instance. It must have outbound internet access directly or through a NAT/VPC endpoint setup.
- `AWS_SECURITY_GROUP_ID`
  - Security group for the builder instance. Inbound can stay empty; outbound internet is required.
- `AWS_INSTANCE_PROFILE_NAME`
  - Instance profile name attached to the builder instance.
- `AWS_EC2_ARM_AMI_PARAMETER`
  - Optional override. Default:
    - `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`
- `AWS_ROLE_TO_ASSUME`
  - Do not store this as a variable. It belongs in GitHub Actions secrets.
- `NIX_BINARY_CACHE_SECRET_KEY`
  - Do not store this as a variable. It belongs in GitHub Actions secrets.

Repository secrets:

- `AWS_ROLE_TO_ASSUME`
  - ARN of the AWS IAM role that GitHub Actions assumes over OIDC.
- `NIX_BINARY_CACHE_SECRET_KEY`
  - Contents of the Nix binary cache private key file.
  - This key signs `.narinfo` metadata before objects are uploaded to S3.

## AWS setup

### 1. Add GitHub OIDC as an IAM identity provider

AWS IAM must trust `token.actions.githubusercontent.com`.

### 2. Create the GitHub Actions control-plane role

This role is assumed by the GitHub workflow over OIDC.

Example trust policy skeleton:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
        }
      }
    }
  ]
}
```

Tighten the `sub` condition if you only want specific branches or environments.

Ready-to-edit templates are included in:

- [github-actions-spot-builder-trust-policy.json](/home/yc/work/khadas/ai/infra/aws/github-actions-spot-builder-trust-policy.json)
- [github-actions-spot-builder-control-plane-policy.json](/home/yc/work/khadas/ai/infra/aws/github-actions-spot-builder-control-plane-policy.json)
- [github-actions-spot-builder-instance-policy.json](/home/yc/work/khadas/ai/infra/aws/github-actions-spot-builder-instance-policy.json)
- [nix-binary-cache-public-read-policy.json](/home/yc/work/khadas/ai/infra/aws/nix-binary-cache-public-read-policy.json)
- [bootstrap-github-actions-spot-builder.sh](/home/yc/work/khadas/ai/infra/aws/bootstrap-github-actions-spot-builder.sh)

Suggested permissions for the control-plane role:

- `ec2:RunInstances`
- `ec2:CreateFleet`
- `ec2:DeleteFleets`
- `ec2:DescribeFleets`
- `ec2:DescribeFleetInstances`
- `ec2:CreateLaunchTemplate`
- `ec2:DeleteLaunchTemplate`
- `ec2:DescribeLaunchTemplates`
- `ec2:TerminateInstances`
- `ec2:DescribeInstances`
- `ec2:DescribeInstanceStatus`
- `ec2:CreateTags`
- `ssm:DescribeInstanceInformation`
- `ssm:SendCommand`
- `ssm:GetCommandInvocation`
- `logs:CreateLogGroup`
- `logs:PutRetentionPolicy`
- `logs:DescribeLogStreams`
- `logs:GetLogEvents`
- `logs:FilterLogEvents`
- `iam:PassRole`

Restrict `iam:PassRole` to the specific builder instance profile role.

### 3. Create the EC2 instance profile role

Attach this role to the builder instance via `AWS_INSTANCE_PROFILE_NAME`.

At minimum it needs:

- `AmazonSSMManagedInstanceCore`

For direct S3 cache pushes it also needs S3 permissions on the cache bucket:

- `s3:GetBucketLocation`
- `s3:ListBucket`
- `s3:GetObject`
- `s3:PutObject`
- `s3:AbortMultipartUpload`
- `s3:ListBucketMultipartUploads`
- `s3:ListMultipartUploadParts`

### 3a. Bootstrap with AWS CLI

The repository includes a bootstrap script that uses AWS CLI and defaults to the `nau` profile:

```bash
AWS_PROFILE=nau \
GITHUB_OWNER=<owner> \
GITHUB_REPO=<repo> \
./infra/aws/bootstrap-github-actions-spot-builder.sh
```

What it does:

- creates the GitHub OIDC provider if it does not already exist
- creates or updates the GitHub Actions control-plane role
- applies the inline control-plane policy used by the workflows
- creates the EC2 builder instance role
- attaches `AmazonSSMManagedInstanceCore`
- attaches the builder S3 cache policy
- creates the instance profile and adds the builder role to it
- creates the regional S3 binary-cache bucket if it does not exist
- applies public-read + bucket encryption configuration

What it does not do:

- create your subnet
- create your security group
- set GitHub secrets and variables for you

After it runs, it prints the exact `AWS_ROLE_TO_ASSUME` and `AWS_INSTANCE_PROFILE_NAME` values to put into GitHub.

### 4. Networking

The builder instance needs outbound access to:

- GitHub
- Nix substituters
- the public S3 binary cache endpoint
- AWS S3 for cache uploads

Inbound access is not required for this workflow.

For cheapest S3 cache traffic from EC2 builders, add an S3 Gateway VPC endpoint to the builder VPC route tables. This avoids NAT data processing charges for S3 traffic and keeps S3 transfers on the AWS network.

What it helps with:

- S3 cache reads by `nix copy` and Nix substituters
- S3 cache writes during `post-build-hook` and final result upload

What it does not replace:

- outbound internet for GitHub
- outbound internet for `releases.nixos.org` and other non-S3 fetches

The repository includes a helper that defaults to the `nau` AWS CLI profile and can infer the VPC and route table from your build subnet:

```bash
AWS_PROFILE=nau \
AWS_REGION=eu-west-3 \
AWS_SUBNET_ID=<your build subnet> \
./infra/aws/create-s3-gateway-endpoint.sh
```

You can also drive it explicitly:

```bash
AWS_PROFILE=nau \
AWS_REGION=eu-west-3 \
AWS_VPC_ID=<vpc-id> \
ROUTE_TABLE_IDS=<rtb-1,rtb-2> \
./infra/aws/create-s3-gateway-endpoint.sh
```

The script prints:

- `VPC_ENDPOINT_ID`
- `AWS_VPC_ID`
- `ROUTE_TABLE_IDS`
- `SERVICE_NAME`

To remove it later:

```bash
AWS_PROFILE=nau aws ec2 delete-vpc-endpoints \
  --region eu-west-3 \
  --vpc-endpoint-ids <vpce-id>
```

## Workflow usage

### Build on GitHub ARM

Use when:

- you want the cheapest possible rebuild
- you do not need more than 4 ARM cores
- you want the simplest path

### Build on EC2 Spot ARM

Use when:

- you want more CPU than GitHub-hosted ARM runners provide
- you want ephemeral builders
- you want to keep the public repository away from self-hosted GitHub runners

Inputs:

- `ref`
  - Git ref to build.
- `target`
  - Flake target, default `vim1s-sd-image`.
- `instance_types`
  - Ordered Graviton Spot preferences.
- `root_volume_gb`
  - Nix builds need disk; 250 GiB is the current default.
- `keep_instance`
  - Leave the instance running if the build fails, for manual debugging.

### Build on EC2 Fleet ARM

Use when:

- you want the same ephemeral builder model as the Spot workflow
- you want AWS to choose among several Spot pools automatically
- you want fewer manual-capacity failures than simple ordered fallback

Inputs:

- `ref`
  - Git ref to build.
- `target`
  - Flake target, default `vim1s-sd-image`.
- `instance_types`
  - Graviton types offered to EC2 Fleet.
- `root_volume_gb`
  - Nix builds need disk; 250 GiB is the current default.
- `keep_instance`
  - Leave the chosen instance running if the build fails, for manual debugging.

## Notes

- The EC2 Spot and EC2 Fleet workflows build from the exact checked-out Git commit and fetch the builder script from that same commit over `raw.githubusercontent.com`.
- The EC2 Fleet workflow uses a temporary launch template plus an `instant` EC2 Fleet request with Spot `price-capacity-optimized`.
- The GitHub ARM workflow uses:
  - `cachix/install-nix-action@v31`
  - `aws-actions/configure-aws-credentials@v5.1.1`
- The GitHub ARM, EC2 Spot, and EC2 Fleet workflows all push finished results with `nix copy --to 's3://…'`.
- The EC2 Spot and EC2 Fleet workflows use plain AWS OIDC + SSM and do not register a GitHub self-hosted runner.
