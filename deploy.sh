#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'

function modifyTaskConfigFile() {
    PARAM_TASK_CONFIG="$1"
    PARAM_IMAGE_CHANGES="$2"
    cp "$PARAM_TASK_CONFIG" job.yml
    cat <<EOF >kustomization.yaml
    resources:
    - job.yml
EOF

    # shellcheck disable=SC2086
    kustomize edit set image $PARAM_IMAGE_CHANGES
    kustomize build . > "$PARAM_TASK_CONFIG"
}

function waitOnJob() {
    PARAM_JOB_NAME="$1"
    retvalComplete=1
    retvalFailed=1
    pollingIterations=0

    set +e
    while [[ $retvalComplete -ne 0 ]] && [[ $retvalFailed -ne 0 ]] && [[ $pollingIterations -lt $INPUT_MAX_POLLING_ITERATIONS ]]; do
        sleep 5

        kubectl wait --for=condition=Failed job.batch/"$PARAM_JOB_NAME" --timeout=0 > /dev/null 2>&1
        retvalFailed=$?

        kubectl wait --for=condition=Complete job.batch/"$PARAM_JOB_NAME" --timeout=0 > /dev/null 2>&1
        retvalComplete=$?

        ((pollingIterations++))
    done
    set -e

    if [ $retvalFailed -eq 0 ]; then
        echo "::error::Migration Job Failed"
        kubectl logs --tail=1000 job.batch/"$PARAM_JOB_NAME"
        exit 1
    fi

    if [[ $pollingIterations -eq $INPUT_MAX_POLLING_ITERATIONS ]]; then
        echo "::error::Max Polling for Job reached, Job Failed"
        kubectl logs --tail=1000 job.batch/"$PARAM_JOB_NAME"
        exit 1
    fi

    echo -e "${GREEN}Job has executed successfully"
}

function waitOnDeployment() {
    PARAM_DEPLOYMENT_NAME="$1"
    PARAM_TIMEOUT="$2"

    set +e
    if ! kubectl rollout status deployment "$PARAM_DEPLOYMENT_NAME" --timeout "$PARAM_TIMEOUT"; then
        echo "::error::Deployment Failed."
        if "$INPUT_ROLLBACK_DEPLOYMENT_ON_FAILURE"; then
            echo -e "${RED}Deployment rollout failed, rollback beginning"
            kubectl rollout undo deployment "$PARAM_DEPLOYMENT_NAME"
            kubectl rollout status deployment "$PARAM_DEPLOYMENT_NAME" --timeout "$PARAM_TIMEOUT"
        fi
        exit 1
    fi
    set -e

    echo -e "${GREEN}Deployment has rolled out successfully"
}

echo -e "ACK Deploy Action for Aliyun on GitHub Actions.";

# Load in values
if [ -n "$INPUT_KUBECONFIG_LOCATION" ]; then
    export KUBECONFIG=$INPUT_KUBECONFIG_LOCATION
    kubectl auth whoami
else
    echo "::error::Access could not be reached to Kubernetes. Double check kubeconfig_location is properly configured."
    exit 1;
fi

# Check if we have a prepare script
if [ -n "$INPUT_PREPARE_TASK_CONFIG_FILEPATH" ] && [ -z "$INPUT_PREPARE_JOB_CONTAINER_IMAGE_CHANGES" ]; then
    echo "::error::Prepare task config filepath was passed, but no prepare container image changes. Ending job."
    exit 1;
fi

if [ -n "$INPUT_PREPARE_JOB_CONTAINER_IMAGE_CHANGES" ] && [ -z "$INPUT_PREPARE_TASK_CONFIG_FILEPATH" ]; then
    echo "::error::Prepare container image changes was passed, but no Prepare Task Config Filepath. Ending job."
    exit 1;
fi

if [ -n "$INPUT_PREPARE_JOB_CONTAINER_IMAGE_CHANGES" ] && [ -z "$INPUT_PREPARE_JOB_NAME" ]; then
    echo "::error::Prepare container image changes was passed, but no Prepare Task Job Name. Ending job."
    exit 1;
fi

if [ -n "$INPUT_PREPARE_JOB_CONTAINER_IMAGE_CHANGES" ] && [ -n "$INPUT_PREPARE_TASK_CONFIG_FILEPATH" ] && [ -n "$INPUT_PREPARE_JOB_NAME" ]; then
    modifyTaskConfigFile "$INPUT_PREPARE_TASK_CONFIG_FILEPATH" "$INPUT_PREPARE_JOB_CONTAINER_IMAGE_CHANGES"

    if "$INPUT_DRY_RUN"; then
        echo "::debug::Dry Run detected. Exiting."
        exit 0;
    fi

    # Execute Prepare Job
    kubectl replace --force -f "$INPUT_PREPARE_TASK_CONFIG_FILEPATH"

    echo -e "${BLUE}Job has been started"

    waitOnJob "$INPUT_PREPARE_JOB_NAME"
fi

if "$INPUT_DRY_RUN"; then
    echo "::debug::Dry Run detected. Exiting."
    exit 0;
fi

echo -e "${ORANGE}Deployment update in progress."

# shellcheck disable=SC2086
kubectl set image deployment/"$INPUT_ACK_DEPLOYMENT_NAME" $INPUT_DEPLOYMENT_CONTAINER_IMAGE_CHANGES

if [ "$INPUT_MAX_POLLING_ITERATIONS" -eq "0" ]; then
    echo -e "${BLUE}Iterations at 0. GitHub Action ending, but container update in-progress to: ${RESET_TEXT}$INPUT_ACK_DEPLOYMENT_NAME";
else
    waitOnDeployment "$INPUT_ACK_DEPLOYMENT_NAME" "$INPUT_ROLLOUT_WATCH_TIMEOUT"
fi

exit 0;
