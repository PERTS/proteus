# Proteus

PERTS-run Canvas server.

## Starting from scratch

* Create a new cloud project.
* Run the steps in `project_setup.sh`.
* Log in to the instance as root.
* Run the steps in `gce_setup_all.sh`.
* Canvas server should now be available on the reserved IP address.
* Modify perts.net DNS in GoDaddy so the A record for canvas.perts.net points at that reserved IP address.

## Connecting to an instance

* Make sure `python --version` reports a version compatible with gcloud. Run `pyenv shell $VERSION` if necessary.
* Install numpy if necessary: `pip install numpy`.

```bash
CLOUDSDK_PYTHON_SITEPACKAGES=1 gcloud compute ssh root@canvas-01 \
  --zone "us-central1-a" \
  --tunnel-through-iap \
  --project $PROJECT_ID
```

## Deleting an instance

```bash
gcloud compute instances delete canvas-01 \
   --zone us-central1-a \
   --project $PROJECT_ID
gcloud compute disks delete canvas-disk-01 \
   --zone us-central1-a \
   --project $PROJECT_ID
```

## Changing a secret in the secrets manager

```bash
echo -n "new-secret-value" | gcloud secrets versions add the-name-of-my-secret \
  --data-file - \
  --project $PROJECT_ID
```
