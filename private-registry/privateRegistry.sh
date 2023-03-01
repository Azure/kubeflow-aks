#!/bin/bash

## Set the name of the log file
LOGFILE="./private-registry/privateRegistry.log"
truncate -s 0 $LOGFILE

# This script is used to pull images from docker hub and push them to private registry
printf "%s\n" "[$(date)] [INFO] Importing Images from Public to Private Registry" | tee -a "$LOGFILE"

# Set the ACR name
RGNAME=kubeflow
ACRNAME=$(az acr list -g $RGNAME --query "[0].name"  -o tsv)

#Set the directory to search for kustomization.yaml files 
DIR="manifests"



# Set the ACR url
ACRURL=$(az acr list -g $RGNAME --query "[0].loginServer" -o tsv)

printf "%s\n" "[$(date)] [DEBUG] Searching for kustomization.yaml files in $DIR" | tee -a "$LOGFILE"
find "$DIR" -type f -name "kustomization.yaml" | while read file; do

  # Search for name and newTag properties in each file
  grep -E "name:|newTag:" $file | while read line; do

    # Check if the line contains a docker container registry starting with gcr.io or docker.io
    if [[ $line =~ name:\ ((gcr\.io|docker\.io)/.+) ]]; then

      # Extract the registry name and store it in a variable
      registry=${BASH_REMATCH[1]}

      # Read the next line which should contain the newTag property
      read next_line

      # Check if the next line contains a newTag property
      if [[ $next_line =~ newTag:\ (.+) ]]; then

        # Extract the tag name and store it in a variable
        tag=${BASH_REMATCH[1]}

        # Concatenate the registry and tag names with a colon delimiter and echo to console
        source_image="$registry:$tag"

        # echo $source_image
        image_name=${registry##*/}:${tag}
        printf "%s\n" "[$(date)] [DEBUG] $image_name found in $file" | tee -a "$LOGFILE"

        # Check if the image already exists on Azure Container Registry using az acr repository show command[^1^][4]
        az acr repository show --name $ACRNAME --image $image_name > /dev/null 2>&1

        # Get the exit code of the command (0 means success, non-zero means failure)
        exit_code=$?

        # If exit code is 0, echo a message that the ACR repository was found and does not need to be imported
        if [ $exit_code -eq 0 ]; then
          printf "%s\n" "[$(date)] [INFO] $image_name already exists on ACR and does not need to be imported" | tee -a "$LOGFILE"
        else
        # Import the image from another container registry to Azure Container Registry using az acr import command[^1^][2]
          printf "%s\n" "[$(date)] [INFO] Importing $source_image" | tee -a $LOGFILE
          az acr import --name $ACRNAME --source $source_image --image $image_name --force 2>> $LOGFILE || printf "%s\n" "[$(date)] [ERROR] Failed to import $source_image" >> $LOGFILE
        fi
      fi
    fi
  done
done

printf "%s\n" "$(date) Done importing Images" | tee -a $LOGFILE
