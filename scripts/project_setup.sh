#!/bin/bash

# To be run by a developer on a new cloud project.

# TODO
# * add command to start a postgres cloud sql instance
# * use additional --create-disk to skip the separate creation and attachment of disks
#   https://cloud.google.com/compute/docs/instances/create-start-instance#sharedimage

PROJECT_ID="proteus-development"
SERVICE_ACCOUNT_NAME="canvas-gce"
SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"
REGION="us-central1"
ZONE="us-central1-a"

# Re: scopes, most are from when I copied this command from the cloud
# console. The `cloud-platform` one is needed for access to secrets API
SCOPES=(
  https://www.googleapis.com/auth/devstorage.read_only
  https://www.googleapis.com/auth/logging.write
  https://www.googleapis.com/auth/monitoring.write
  https://www.googleapis.com/auth/servicecontrol
  https://www.googleapis.com/auth/service.management.readonly
  https://www.googleapis.com/auth/trace.append
  https://www.googleapis.com/auth/cloud-platform
)
SCOPES_JOINED=$(IFS=, ; echo "${SCOPES[*]}")

# Using 200GB as minimum size recommended by CLI. It says:
# > WARNING: You have selected a disk size of under [200GB].
# > This may result in poor I/O performance. For more information,
# > see: https://developers.google.com/compute/docs/disks#performance.
ATTACHED_DISK_SIZE="200GB"

# Canvas docs say it "likes RAM". Not sure which is best.
#MACHINE_TYPE="n2-standard-2" # 8 GB memory
MACHINE_TYPE="n2-standard-4" # 16 GB memory
#MACHINE_TYPE="n2-standard-8" # 32 GB memory

# Reserve an IP address to assign to the instance.
gcloud compute addresses create canvas-dev \
  --region $REGION \
  --project $PROJECT_ID
# See the IP address
CANVAS_IP=$(gcloud compute addresses describe canvas-dev \
  --region $REGION \
  --project $PROJECT_ID | yq --raw-output '.address')

# NOT DOCUMENTED: create a postgres instance in Cloud SQL

# Create a database in that instance.
gcloud sql databases create canvas_production \
  --instance development-01 \
  --project $PROJECT_ID
# Create a user
PASSWORD=$(gcloud secrets versions access latest \
  --secret "canvas-db-password" \
  --project $PROJECT_ID\
)
gcloud sql users create canvas \
  --instance development-01 \
  --password $PASSWORD \
  --project $PROJECT_ID

gcloud services enable secretmanager.googleapis.com  --project $PROJECT_ID
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
  --display-name $SERVICE_ACCOUNT_NAME \
  --description "Runs Canvas GCE instances" \
  --project $PROJECT_ID
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role "roles/secretmanager.secretAccessor" \
    --role "roles/cloudsql.client"

# Create all necessary secrets
declare -A secret_array
secret_array=( 
  # Password for the postgres db user the app will connect with.
  [canvas-db-password]="???"
  # Password for the admin account of the app.
  [canvas-lms-admin-password]="???"
  # Encryption key for canvas auth sessions
  [canvas-security-key]="???"
  # Encryption secrets for the canvas rich text editor
  [canvas-rce-cipher-password]="???"
  [canvas-rce-secret]="???"
  [canvas-rce-key]="???"
  # API keys for image and video upload integrations with the rich text editor.
  [flickr-api-key]="???"
  [youtube-api-key]="???"
  # Certificates for SSL/TLS connections to canvas.perts.net
  [canvas-perts-net-ssl-key]="???"
  [canvas-perts-net-bundle-crt]="???"
  [canvas-perts-net-crt]="???"
  [mandrill-api-key]="???"
)

existing_secrets=$(gcloud secrets list --project $PROJECT_ID)
for secret_name secret_value in ${(kv)secret_array}
do
  if echo $existing_secrets | grep -q $secret_name
  then
    echo "$secret_name already set. Value NOT checked."
  else
    echo -n "$secret_value" | gcloud secrets create $secret_name \
      --replication-policy "automatic" \
      --data-file - \
      --project $PROJECT_ID
  fi
done

DISK_ARGS=(
  auto-delete=yes
  boot=yes
  image=projects/ubuntu-os-cloud/global/images/ubuntu-2004-focal-v20240307b
  mode=rw
  size=10
  type=projects/$PROJECT_ID/zones/$ZONE/diskTypes/pd-balanced
)
DISK_JOINED=$(IFS=, ; echo "${DISK_ARGS[*]}")

gcloud compute disks create canvas-disk-01 \
  --size $ATTACHED_DISK_SIZE \
  --type pd-standard \
  --zone $ZONE \
  --project $PROJECT_ID
gcloud compute instances create canvas-01 \
  --address $CANVAS_IP \
  --zone $ZONE \
  --machine-type $MACHINE_TYPE \
  --network-interface network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
  --maintenance-policy MIGRATE \
  --provisioning-model STANDARD \
  --service-account $SERVICE_ACCOUNT_EMAIL \
  --scopes $SCOPES_JOINED \
  --tags http-server,https-server,lb-health-check \
  --create-disk $DISK_ARGS \
  --no-shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --labels goog-ec-src=vm_add-gcloud \
  --reservation-affinity any \
  --project $PROJECT_ID
gcloud compute instances attach-disk canvas-01 \
  --disk canvas-disk-01 \
  --device-name sdb \
  --zone $ZONE \
  --project $PROJECT_ID
