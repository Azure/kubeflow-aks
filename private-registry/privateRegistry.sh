#!/bin/bash

# Functions

process_files(){
  # load array into a bash array
  # output each entry as a single line json
  readarray imageMappings < <(yq -o=j -I=0 '.images[]' "$file" )

  for imageMapping in "${imageMappings[@]}"; do

      name=$(echo "$imageMapping" | yq '.name' -)
      newName=$(echo "$imageMapping" | yq '.newName' -)
      newTag=$(echo "$imageMapping" | yq '.newTag' -)

      source_image="$name:$newTag"
      image_name=${name##*/}:${newTag}

      if [[ $name =~ ((gcr\.io|docker\.io)/.+) ]]; then

        #Check if the image already exists on Azure Container Registry using az acr repository show command[^1^][4]
        az acr repository show --name $ACRNAME --image $image_name > /dev/null 2>&1

        # Get the exit code of the command (0 means success, non-zero means failure)
        exit_code=$?
        
        updated_image_name="${ACRURL}/${name##*/}"

        # If exit code is 0, echo a message that the ACR repository was found and does not need to be imported
        if [ $exit_code -eq 0 ]; then
          printf "%s\n" "[$(date)] [INFO] $image_name already exists on ACR and does not need to be imported" | tee -a "$LOGFILE"
          yq eval ".images[] |= select(.name == \"$name\") |= .newName |= \"$updated_image_name\"" -i $file
        
        else
          printf "%s\n" "[$(date)] [INFO] Importing $source_image" | tee -a $LOGFILE
          az acr import --name $ACRNAME --source $source_image --image $image_name --force

          if [ $? -eq 0 ]; then
            # Update the kustomization.yaml file with the new image name
            yq eval ".images[] |= select(.name == \"$name\") |= .newName |= \"$updated_image_name\"" -i $file

          else
            # Log error messages
            printf "%s\n" "[$(date)] [ERROR] Failed to import $source_image" >> $LOGFILE
            return 2>> $LOGFILE
          fi
        fi
      fi
  done
}

## Set the name of the log file
LOGFILE="privateRegistry.log"
truncate -s 0 $LOGFILE

# This script is used to pull images from docker hub and push them to private registry
printf "%s\n" "[$(date)] [INFO] Importing Images from Public to Private Registry" | tee -a "$LOGFILE"

# Set the ACR name
RGNAME=kubeflow
ACRNAME=$(az acr list -g $RGNAME --query "[0].name"  -o tsv)

#Set the directory to search for kustomization.yaml files 
DIR="../manifests"

# Set the ACR url
ACRURL=$(az acr list -g $RGNAME --query "[0].loginServer" -o tsv)

printf "%s\n" "[$(date)] [DEBUG] Searching for kustomization.yaml files in $DIR" | tee -a "$LOGFILE"
find "$DIR" -type f -name "kustomization.yaml" | while read file; do
  process_files
done

printf "%s\n" "$(date) Done importing Images" | tee -a $LOGFILE

