#!/bin/bash
# This script is used to pull images from docker hub and push them to private registry

# Set the ACR name
RGNAME=kubeflow
ACRNAME=$(az acr list -g $RGNAME --query "[0].name"  -o tsv)
DIR="manifests"

find "$DIR" -type f -name "kustomization.yaml" | while read file; do
  images=($(grep -E "(gcr\io|docker\.io)" "$file" | cut -d ":" -f 2- | sort -u)) 

  for image in ${images[@]}; do
    # Get the image name without the registry prefix
      image_name=${image##*/}

      # Check if the image exists in acr
      az acr manifest list-metadata --registry $ACRNAME --name $image_name > /dev/null 2>&1

      # Get the exit code of the previous command
      status=$?

      # If status is not 0, it means the image does not exist
      if [ $status -ne 0 ]; then

        echo "Importing ${image_name}"
        # Import the image from docker.io to acr
        az acr import --name $ACRNAME --source $image --image $image_name

      else

        echo "${image_name} already exists"

      fi

  done
done

echo "Done importing Images"