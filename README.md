# PetRescue OCI Deployment — Terraform

This Terraform module provisions a single Ampere A1 VM on Oracle Cloud Infrastructure for the cloud arm of the PetRescue experiment, with all networking and a bootstrap that installs .NET 10 ARM64, Docker, and Python.

## What gets created

- One VCN (10.0.0.0/16) with one public subnet (10.0.1.0/24)
- An internet gateway and route table
- A security list opening ports 22, 8080, 5055, and ICMP
- One Ampere A1.Flex compute instance running Ubuntu 22.04 ARM64

Default shape: 2 OCPUs / 12 GB RAM / 50 GB boot. All within the Always Free quota.

The instance is bootstrapped via `cloud-init.yaml`, which installs Docker, Python 3 with venv, PostgreSQL client, .NET 10 ASP.NET Core runtime, and fixes the OCI Ubuntu iptables (which would otherwise block ports 8080 and 5055 even with the security list open).

## Prerequisites

You need three things on your Mac before `terraform apply` will work.

### 1. Terraform

```bash
brew install terraform
terraform version
# expect: Terraform v1.5+ (any 1.x is fine, but the OCI provider needs >=1.5)
```

### 2. OCI CLI configured

Terraform's OCI provider reads `~/.oci/config` for authentication. The fastest way to create that file is via the OCI CLI:

```bash
brew install oci-cli   # or: pip install oci-cli
oci setup config
```

It will prompt you for:
- User OCID (Profile menu > User Settings in OCI Console)
- Tenancy OCID (Profile menu > Tenancy)
- Region
- Whether to generate a new API key (say yes — this is the OCI API key, not the SSH key for the VM)

After it finishes you'll have `~/.oci/config` and `~/.oci/oci_api_key.pem`. Upload the public half (`~/.oci/oci_api_key_public.pem`) to your OCI user in **Profile > User Settings > API Keys > Add API Key**.

Verify it works:

```bash
oci iam region list
```

If that returns a JSON list of regions, you're authenticated.

### 3. Your tenancy OCID and SSH public key handy

You'll paste these into `terraform.tfvars` in the next section.

## How to run

```bash
# 1. Copy the tfvars template and fill it in
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
# Set tenancy_ocid, region, ssh_public_key. Other values are optional.

# 2. Initialize Terraform (downloads the OCI provider, ~30s)
terraform init

# 3. See what will be created
terraform plan

# 4. Apply
terraform apply
# Type `yes` when prompted. Provisioning takes 1-3 minutes.

# 5. Read the outputs
terraform output next_steps
```

The `next_steps` output prints the public IP, the SSH command, and copy-paste instructions for the rest of the deployment.

## How to verify the bootstrap finished

After `terraform apply` returns, cloud-init still takes 2-3 minutes to finish installing packages. Watch the progress:

```bash
ssh -i ~/.ssh/petrescue_oci ubuntu@$(terraform output -raw public_ip) \
    'tail -f /var/log/cloud-init-output.log'
```

Wait for the line:

```
==========================================
PetRescue bootstrap complete.
==========================================
```

That's your signal that .NET 10, Docker, and Python are all installed.

## Common issues

### `Out of host capacity` when provisioning Ampere A1

This is the #1 OCI Free Tier issue. Oracle's Ampere A1 capacity rotates between availability domains and regions. Two workarounds:

1. **Try a different AD.** Edit `main.tf` and change `availability_domains[0].name` to `[1]` or `[2]`. Re-run `terraform apply`.
2. **Try a less-busy region.** Bombay (`ap-mumbai-1`), Phoenix (`us-phoenix-1`), or São Paulo (`sa-saopaulo-1`) are usually less saturated than Frankfurt or Ashburn.
3. **Upgrade to Pay-As-You-Go.** This does not bill you for Always Free resources but removes the capacity gating. A common community recommendation.

### `403 NotAuthorizedOrNotFound` on plan/apply

Your `~/.oci/config` has wrong OCIDs, or the API key isn't uploaded to your OCI user. Re-run `oci setup config` and re-upload the public key.

### SSH hangs after `terraform apply`

Three possibilities:
1. Cloud-init is still running (give it 2-3 minutes)
2. iptables hasn't been fixed yet (cloud-init does this within the first 30 seconds, but if you SSH immediately you can hit a window where it's still locked down)
3. The security list rule didn't apply — verify in the OCI Console under Networking > VCNs > petrescue-vcn > Security Lists

If port 22 specifically is blocked, that means `allowed_ssh_cidr` is wrong. The default `0.0.0.0/0` allows everyone; if you tightened it to your IP, double-check that IP is current (`curl ifconfig.me`).

## Tearing it down

```bash
terraform destroy
# Type `yes`
```

This removes everything: the VM, the VCN, the security list, the route table, the IGW. Total cleanup takes ~1 minute. Always Free resources don't bill, but destroying is good hygiene and frees Ampere A1 capacity for your next provision.

## For the paper

Cite this Terraform module as the reproducibility artifact. The methodology section can say:

> *"The cloud configuration was provisioned via Terraform on Oracle Cloud Infrastructure, region X, using the Always Free Ampere A1.Flex shape with 2 OCPUs and 12 GB of RAM, running Ubuntu 22.04 ARM64 with .NET 10 ASP.NET Core runtime. Full provisioning code is available at [github URL]."*

That's all reviewers need.
