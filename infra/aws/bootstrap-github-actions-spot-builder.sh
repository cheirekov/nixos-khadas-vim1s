#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-nau}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
GITHUB_OWNER="${GITHUB_OWNER:?GITHUB_OWNER is required}"
GITHUB_REPO="${GITHUB_REPO:?GITHUB_REPO is required}"

CONTROL_PLANE_ROLE_NAME="${CONTROL_PLANE_ROLE_NAME:-github-actions-spot-builder-control-plane}"
CONTROL_PLANE_POLICY_NAME="${CONTROL_PLANE_POLICY_NAME:-github-actions-spot-builder-control-plane}"
BUILDER_INSTANCE_ROLE_NAME="${BUILDER_INSTANCE_ROLE_NAME:-github-actions-spot-builder-instance}"
BUILDER_INSTANCE_POLICY_NAME="${BUILDER_INSTANCE_POLICY_NAME:-github-actions-spot-builder-instance-s3-cache}"
BUILDER_INSTANCE_PROFILE_NAME="${BUILDER_INSTANCE_PROFILE_NAME:-github-actions-spot-builder-instance-profile}"
NIX_CACHE_BUCKET_NAME="${NIX_CACHE_BUCKET_NAME:-nix-cache-vim1s-${AWS_REGION}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUST_TEMPLATE="${SCRIPT_DIR}/github-actions-spot-builder-trust-policy.json"
CONTROL_PLANE_TEMPLATE="${SCRIPT_DIR}/github-actions-spot-builder-control-plane-policy.json"
BUILDER_INSTANCE_TEMPLATE="${SCRIPT_DIR}/github-actions-spot-builder-instance-policy.json"
BUCKET_POLICY_TEMPLATE="${SCRIPT_DIR}/nix-binary-cache-public-read-policy.json"

log() {
  printf '[aws-bootstrap] %s\n' "$*"
}

aws_cli() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

render_template() {
  local input="${1:?input is required}"
  local output="${2:?output is required}"

  sed \
    -e "s|<ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<OWNER>|${GITHUB_OWNER}|g" \
    -e "s|<REPO>|${GITHUB_REPO}|g" \
    -e "s|<REGION>|${AWS_REGION}|g" \
    -e "s|<BUILDER_INSTANCE_ROLE_NAME>|${BUILDER_INSTANCE_ROLE_NAME}|g" \
    -e "s|<NIX_CACHE_BUCKET_NAME>|${NIX_CACHE_BUCKET_NAME}|g" \
    "${input}" > "${output}"
}

ensure_oidc_provider() {
  OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

  if aws_cli iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
    log "GitHub OIDC provider already exists"
    return
  fi

  log "creating GitHub OIDC provider"
  aws_cli iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" >/dev/null
}

ensure_control_plane_role() {
  local trust_json policy_json
  trust_json="$(mktemp)"
  policy_json="$(mktemp)"

  render_template "${TRUST_TEMPLATE}" "${trust_json}"
  render_template "${CONTROL_PLANE_TEMPLATE}" "${policy_json}"

  if aws_cli iam get-role --role-name "${CONTROL_PLANE_ROLE_NAME}" >/dev/null 2>&1; then
    log "updating assume-role policy for ${CONTROL_PLANE_ROLE_NAME}"
    aws_cli iam update-assume-role-policy \
      --role-name "${CONTROL_PLANE_ROLE_NAME}" \
      --policy-document "file://${trust_json}"
  else
    log "creating control-plane role ${CONTROL_PLANE_ROLE_NAME}"
    aws_cli iam create-role \
      --role-name "${CONTROL_PLANE_ROLE_NAME}" \
      --assume-role-policy-document "file://${trust_json}" \
      --description "GitHub Actions OIDC role for ephemeral EC2 Spot/Fleet builders" >/dev/null
  fi

  log "putting inline policy ${CONTROL_PLANE_POLICY_NAME} on ${CONTROL_PLANE_ROLE_NAME}"
  aws_cli iam put-role-policy \
    --role-name "${CONTROL_PLANE_ROLE_NAME}" \
    --policy-name "${CONTROL_PLANE_POLICY_NAME}" \
    --policy-document "file://${policy_json}"
}

ensure_builder_instance_role() {
  local ec2_trust_json builder_policy_json
  ec2_trust_json="$(mktemp)"
  builder_policy_json="$(mktemp)"
  render_template "${BUILDER_INSTANCE_TEMPLATE}" "${builder_policy_json}"

  cat > "${ec2_trust_json}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  if aws_cli iam get-role --role-name "${BUILDER_INSTANCE_ROLE_NAME}" >/dev/null 2>&1; then
    log "builder instance role ${BUILDER_INSTANCE_ROLE_NAME} already exists"
  else
    log "creating builder instance role ${BUILDER_INSTANCE_ROLE_NAME}"
    aws_cli iam create-role \
      --role-name "${BUILDER_INSTANCE_ROLE_NAME}" \
      --assume-role-policy-document "file://${ec2_trust_json}" \
      --description "EC2 instance role for ephemeral Nix builders over SSM" >/dev/null
  fi

  log "attaching AmazonSSMManagedInstanceCore to ${BUILDER_INSTANCE_ROLE_NAME}"
  aws_cli iam attach-role-policy \
    --role-name "${BUILDER_INSTANCE_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null || true

  log "putting inline policy ${BUILDER_INSTANCE_POLICY_NAME} on ${BUILDER_INSTANCE_ROLE_NAME}"
  aws_cli iam put-role-policy \
    --role-name "${BUILDER_INSTANCE_ROLE_NAME}" \
    --policy-name "${BUILDER_INSTANCE_POLICY_NAME}" \
    --policy-document "file://${builder_policy_json}"

  if aws_cli iam get-instance-profile --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
    log "instance profile ${BUILDER_INSTANCE_PROFILE_NAME} already exists"
  else
    log "creating instance profile ${BUILDER_INSTANCE_PROFILE_NAME}"
    aws_cli iam create-instance-profile \
      --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" >/dev/null
  fi

  if aws_cli iam get-instance-profile --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" \
      --query "InstanceProfile.Roles[?RoleName=='${BUILDER_INSTANCE_ROLE_NAME}'] | length(@)" \
      --output text | grep -qx '1'; then
    log "instance role already attached to profile"
  else
    log "adding ${BUILDER_INSTANCE_ROLE_NAME} to ${BUILDER_INSTANCE_PROFILE_NAME}"
    aws_cli iam add-role-to-instance-profile \
      --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" \
      --role-name "${BUILDER_INSTANCE_ROLE_NAME}"
    sleep 10
  fi
}

ensure_binary_cache_bucket() {
  local bucket_policy_json
  bucket_policy_json="$(mktemp)"
  render_template "${BUCKET_POLICY_TEMPLATE}" "${bucket_policy_json}"

  if aws_cli s3api head-bucket --bucket "${NIX_CACHE_BUCKET_NAME}" >/dev/null 2>&1; then
    log "binary cache bucket ${NIX_CACHE_BUCKET_NAME} already exists"
  else
    log "creating binary cache bucket ${NIX_CACHE_BUCKET_NAME}"
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
      aws_cli s3api create-bucket \
        --bucket "${NIX_CACHE_BUCKET_NAME}" >/dev/null
    else
      aws_cli s3api create-bucket \
        --bucket "${NIX_CACHE_BUCKET_NAME}" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
    fi
  fi

  log "configuring public-read policy for ${NIX_CACHE_BUCKET_NAME}"
  aws_cli s3api put-public-access-block \
    --bucket "${NIX_CACHE_BUCKET_NAME}" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false" >/dev/null
  aws_cli s3api put-bucket-encryption \
    --bucket "${NIX_CACHE_BUCKET_NAME}" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  aws_cli s3api put-bucket-policy \
    --bucket "${NIX_CACHE_BUCKET_NAME}" \
    --policy "file://${bucket_policy_json}" >/dev/null
}

print_outputs() {
  cat <<EOF

GitHub configuration:
  secret AWS_ROLE_TO_ASSUME=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CONTROL_PLANE_ROLE_NAME}
  var AWS_REGION=${AWS_REGION}
  var AWS_INSTANCE_PROFILE_NAME=${BUILDER_INSTANCE_PROFILE_NAME}
  secret NIX_BINARY_CACHE_SECRET_KEY=<contents of your binary cache private key file>

Still needed from your VPC:
  var AWS_SUBNET_ID=<subnet with outbound internet/NAT>
  var AWS_SECURITY_GROUP_ID=<security group with outbound internet>

Binary cache:
  bucket=${NIX_CACHE_BUCKET_NAME}
  public_url=https://${NIX_CACHE_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com
  signing_key_name=${NIX_CACHE_BUCKET_NAME}

AWS profile used:
  ${AWS_PROFILE}
EOF
}

AWS_ACCOUNT_ID="$(aws_cli sts get-caller-identity --query 'Account' --output text)"

ensure_oidc_provider
ensure_control_plane_role
ensure_builder_instance_role
ensure_binary_cache_bucket
print_outputs
