# variables.tf — Inputs for the PetRescue OCI deployment.
#
# Required values must be set in terraform.tfvars (copy from terraform.tfvars.example).

variable "tenancy_ocid" {
  description = "OCID of your OCI tenancy (Profile menu > Tenancy)."
  type        = string
  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.oc1\\.", var.tenancy_ocid))
    error_message = "Tenancy OCID must start with 'ocid1.tenancy.oc1.'"
  }
}

variable "region" {
  description = "OCI home region, e.g. eu-frankfurt-1, uk-london-1, us-ashburn-1."
  type        = string
}

variable "ssh_public_key" {
  description = "Contents of your SSH public key file (the .pub one). Paste, do not point at a path."
  type        = string
  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) ", var.ssh_public_key))
    error_message = "Must be a valid OpenSSH public key starting with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*."
  }
}

# Optional, with sensible defaults --------------------------------------------

variable "instance_name" {
  description = "Name shown in the OCI console for the compute instance."
  type        = string
  default     = "petrescue-cloud"
}

variable "instance_ocpus" {
  description = "OCPU count for the Ampere A1.Flex instance. Always Free quota total is 4."
  type        = number
  default     = 2
  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4
    error_message = "Always Free quota allows 1 to 4 OCPUs per instance."
  }
}

variable "instance_memory_gb" {
  description = "Memory in GB for the Ampere A1.Flex instance. Always Free quota total is 24."
  type        = number
  default     = 12
  validation {
    condition     = var.instance_memory_gb >= 6 && var.instance_memory_gb <= 24
    error_message = "Always Free quota allows 6 to 24 GB per instance."
  }
}

variable "boot_volume_size_gb" {
  description = "Boot volume size. Default 50 is enough for .NET 10 + Docker images. Free quota is 200 across all VMs."
  type        = number
  default     = 50
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH. Default 0.0.0.0/0 for convenience; tighten to your IP for security."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_http_cidr" {
  description = "CIDR allowed to hit the API (port 8080) and sidecar (port 5055)."
  type        = string
  default     = "0.0.0.0/0"
}
