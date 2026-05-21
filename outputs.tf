# outputs.tf — What you need after `terraform apply`.

output "public_ip" {
  description = "Public IPv4 address of the PetRescue VM."
  value       = oci_core_instance.petrescue.public_ip
}

output "ssh_command" {
  description = "Ready-to-paste SSH command. Replace ~/.ssh/petrescue_oci with your actual private key path if different."
  value       = "ssh -i ~/.ssh/petrescue_oci ubuntu@${oci_core_instance.petrescue.public_ip}"
}

output "next_steps_slice1" {
  description = "Deploy Slice 1 (monolith) to the VM after cloud-init finishes."
  value = <<-EOT

    ============================================================
    SLICE 1 — Monolith deployment
    VM Public IP: ${oci_core_instance.petrescue.public_ip}
    ============================================================

    1. WAIT 2-3 MINUTES for cloud-init to finish. Watch with:

         ssh -i ~/.ssh/petrescue_oci ubuntu@${oci_core_instance.petrescue.public_ip} \
             'tail -f /var/log/cloud-init-output.log'

       Wait for: "PetRescue bootstrap complete."

    2. PUBLISH the monolith on your Mac (ARM64 self-contained false):

         cd /path/to/petrescue-net-slice1/src/PetRescue.Api
         dotnet publish -c Release -r linux-arm64 --self-contained false \
             -o /tmp/petrescue-slice1-publish
         scp -i ~/.ssh/petrescue_oci -r /tmp/petrescue-slice1-publish \
             ubuntu@${oci_core_instance.petrescue.public_ip}:~/petrescue-slice1

    3. COPY supporting files:

         cd /path/to/petrescue-net-slice1
         scp -i ~/.ssh/petrescue_oci -r sidecar sql docker-compose.yml scripts/prepare_data.sh \
             ubuntu@${oci_core_instance.petrescue.public_ip}:~/slice1/

    4. ON THE VM — start infrastructure, apply schema, seed data:

         ssh -i ~/.ssh/petrescue_oci ubuntu@${oci_core_instance.petrescue.public_ip}
         cd ~/slice1 && docker compose up -d
         sleep 5
         psql "$PETRESCUE_PG" -f sql/00_schema.sql
         psql "$PETRESCUE_PG" -f sql/01_seed.sql
         bash prepare_data.sh

    5. ON THE VM — start the monolith (listens on :8080):

         cd ~/petrescue-slice1
         ASPNETCORE_URLS=http://0.0.0.0:8080 dotnet PetRescue.Api.dll &

    6. ON THE VM — start the CodeCarbon sidecar (listens on :5055):

         cd ~/slice1/sidecar
         python3 -m venv .venv && source .venv/bin/activate
         pip install -r requirements.txt
         python sidecar.py &

    7. FROM YOUR MAC — run the experiment:

         cd /path/to/petrescue-net-slice1/scripts
         ./run_experiment.sh \
             --runs 3 \
             --api-url http://${oci_core_instance.petrescue.public_ip}:8080 \
             --sidecar-url http://${oci_core_instance.petrescue.public_ip}:5055 \
             --output ../results/oci_slice1_$(date +%Y%m%d).csv

  EOT
}

output "next_steps_slice2" {
  description = "Deploy Slice 2 (microservices) to the VM after Slice 1 experiments are done."
  value = <<-EOT

    ============================================================
    SLICE 2 — Microservices deployment
    VM Public IP: ${oci_core_instance.petrescue.public_ip}
    ============================================================

    Stop Slice 1 first:
         ssh -i ~/.ssh/petrescue_oci ubuntu@${oci_core_instance.petrescue.public_ip} \
             'pkill -f PetRescue.Api.dll; cd ~/slice1 && docker compose down'

    1. PUBLISH all four services on your Mac (ARM64):

         cd /path/to/petrescue-net-slice2
         for svc in PetRescue.Gateway PetRescue.Animals.Api PetRescue.Medical.Api PetRescue.Adopters.Api; do
           dotnet publish src/$svc/$svc.csproj -c Release -r linux-arm64 --self-contained false \
               -o /tmp/petrescue-slice2/$svc
         done
         scp -i ~/.ssh/petrescue_oci -r /tmp/petrescue-slice2 \
             ubuntu@${oci_core_instance.petrescue.public_ip}:~/petrescue-slice2

    2. COPY supporting files:

         cd /path/to/petrescue-net-slice2
         scp -i ~/.ssh/petrescue_oci -r sidecar sql docker-compose.yml \
             scripts/prepare_data.sh scripts/start_services.sh scripts/stop_services.sh \
             ubuntu@${oci_core_instance.petrescue.public_ip}:~/slice2/

    3. ON THE VM — start infrastructure, apply schema, seed data:

         ssh -i ~/.ssh/petrescue_oci ubuntu@${oci_core_instance.petrescue.public_ip}
         cd ~/slice2 && docker compose up -d
         sleep 5
         psql "$PETRESCUE_PG" -f sql/00_schema.sql
         psql "$PETRESCUE_PG" -f sql/01_seed.sql
         bash prepare_data.sh

    4. ON THE VM — start all four services via the existing script:

         cd ~/slice2
         PUBLISH_ROOT=~/petrescue-slice2 bash start_services.sh baseline
         # Services start in order: Adopters :5103, Animals :5101, Medical :5102, Gateway :8080
         # Verify: curl http://localhost:8080/health

    5. ON THE VM — start the CodeCarbon sidecar:

         cd ~/slice2/sidecar
         python3 -m venv .venv && source .venv/bin/activate
         pip install -r requirements.txt
         python sidecar.py &

    6. FROM YOUR MAC — run the experiment (same command, same endpoint):

         cd /path/to/petrescue-net-slice2/scripts
         ./run_experiment.sh \
             --runs 3 \
             --api-url http://${oci_core_instance.petrescue.public_ip}:8080 \
             --sidecar-url http://${oci_core_instance.petrescue.public_ip}:5055 \
             --output ../results/oci_slice2_$(date +%Y%m%d).csv

    7. STOP services when done:

         ssh -i ~/.ssh/petrescue_oci ubuntu@${oci_core_instance.petrescue.public_ip} \
             'cd ~/slice2 && bash stop_services.sh && docker compose down'

  EOT
}

output "teardown" {
  description = "Destroy all OCI resources when experiments are complete."
  value       = "terraform destroy   # removes VM, VCN, subnet, IGW, security list"
}
