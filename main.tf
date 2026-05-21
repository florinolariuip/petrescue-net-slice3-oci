# main.tf — PetRescue OCI deployment.
#
# Creates: VCN, public subnet, internet gateway, route table, security list,
# and a single Ampere A1.Flex compute instance running Ubuntu 22.04 ARM64.
#
# The instance is bootstrapped via cloud-init.yaml — see that file for what
# gets installed (Docker, Python venv, .NET 10 ARM64 runtime, iptables fix).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider configuration.
#
# Authentication: we use OCI's "user_principal" config-file mode by default.
# That means you must have run `oci setup config` once on this machine, which
# writes ~/.oci/config with your user OCID, fingerprint, and private API key.
#
# Alternative: use OCI Cloud Shell, where authentication is implicit.
# -----------------------------------------------------------------------------
provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
  # The other auth params (user_ocid, fingerprint, private_key_path) come from
  # ~/.oci/config automatically.
}

# -----------------------------------------------------------------------------
# Resolve a couple of things from the tenancy automatically.
# -----------------------------------------------------------------------------

# List availability domains in the region. Ampere A1 capacity rotates between
# ADs, so we'll iterate over them at instance-creation time.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Use the root compartment for everything. For a production setup you'd create
# a dedicated compartment; for an academic experiment, root is fine and simpler.
locals {
  compartment_id = var.tenancy_ocid
}

# Pick the Ubuntu 22.04 ARM64 image dynamically so we always get the latest.
# Filtering by display name pattern is the standard OCI approach.
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  # Pick the Minimal aarch64 image if available; fall back to standard.
  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-22\\.04-aarch64-.*"]
    regex  = true
  }
}

# -----------------------------------------------------------------------------
# Networking: VCN -> public subnet -> internet gateway -> route table.
# -----------------------------------------------------------------------------

resource "oci_core_vcn" "petrescue" {
  compartment_id = local.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "petrescue-vcn"
  dns_label      = "petrescuevcn"
}

resource "oci_core_internet_gateway" "petrescue" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.petrescue.id
  display_name   = "petrescue-igw"
}

resource "oci_core_route_table" "petrescue" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.petrescue.id
  display_name   = "petrescue-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.petrescue.id
  }
}

# Security list: open SSH, the API (8080), and the sidecar (5055).
# Egress is wide open (default).
resource "oci_core_security_list" "petrescue" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.petrescue.id
  display_name   = "petrescue-sl"

  # Egress: allow everything outbound (needed for apt, NuGet, pip, etc.)
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  # Ingress: SSH
  ingress_security_rules {
    source      = var.allowed_ssh_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    stateless   = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Ingress: API gateway / monolith (port 8080)
  ingress_security_rules {
    source      = var.allowed_http_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    stateless   = false
    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # Ingress: CodeCarbon sidecar (port 5055)
  ingress_security_rules {
    source      = var.allowed_http_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    stateless   = false
    tcp_options {
      min = 5055
      max = 5055
    }
  }

  # Ingress: ICMP (for ping diagnostics)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "1" # ICMP
    stateless   = false
  }
}

resource "oci_core_subnet" "petrescue_public" {
  compartment_id    = local.compartment_id
  vcn_id            = oci_core_vcn.petrescue.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "petrescue-public"
  dns_label         = "pubsubnet"
  route_table_id    = oci_core_route_table.petrescue.id
  security_list_ids = [oci_core_security_list.petrescue.id]

  # This is what makes a subnet "public": public IPs are allowed on its NICs.
  prohibit_public_ip_on_vnic = false
}

# -----------------------------------------------------------------------------
# Compute instance.
# -----------------------------------------------------------------------------

resource "oci_core_instance" "petrescue" {
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.petrescue_public.id
    assign_public_ip = true
    hostname_label   = "petrescue"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(file("${path.module}/cloud-init.yaml"))
  }

  # If the first AD has no capacity, try the next one.
  # OCI doesn't have built-in AD-fallback in Terraform; if you hit "Out of host
  # capacity", change the [0] above to [1] or [2] manually and re-apply.
  lifecycle {
    ignore_changes = [
      source_details[0].source_id, # don't replace on new Ubuntu image releases
    ]
  }
}
