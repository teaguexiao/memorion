#!/bin/bash

# Script to ensure OpusKit.framework dSYM is properly included in the archive
# This script should be added as a Run Script Build Phase in Xcode

set -e
set -x

echo "Starting dSYM copy script for OpusKit.framework"

# Find all OpusKit.framework directories in the build products directory
find "${BUILT_PRODUCTS_DIR}" -name "OpusKit.framework" -type d | while read -r FRAMEWORK_PATH; do
    echo "Found OpusKit.framework at: ${FRAMEWORK_PATH}"
    
    # Get the framework name without extension
    FRAMEWORK_NAME=$(basename "${FRAMEWORK_PATH}" .framework)
    
    # Check if dSYM exists
    DSYM_PATH="${FRAMEWORK_PATH}.dSYM"
    if [ ! -d "${DSYM_PATH}" ]; then
        echo "dSYM not found for ${FRAMEWORK_PATH}, attempting to generate it"
        
        # Generate dSYM file
        BINARY_PATH="${FRAMEWORK_PATH}/${FRAMEWORK_NAME}"
        if [ -f "${BINARY_PATH}" ]; then
            echo "Generating dSYM for ${BINARY_PATH}"
            xcrun dsymutil "${BINARY_PATH}" -o "${DSYM_PATH}"
            
            if [ -d "${DSYM_PATH}" ]; then
                echo "Successfully generated dSYM at ${DSYM_PATH}"
            else
                echo "Failed to generate dSYM for ${FRAMEWORK_NAME}"
            fi
        else
            echo "Binary not found at ${BINARY_PATH}"
        fi
    else
        echo "dSYM already exists at ${DSYM_PATH}"
    fi
    
    # Ensure dSYM is copied to the correct location in the archive
    if [ -d "${DSYM_PATH}" ]; then
        echo "Copying dSYM to ${BUILT_PRODUCTS_DIR}/../../../dSYMs/"
        mkdir -p "${BUILT_PRODUCTS_DIR}/../../../dSYMs/"
        cp -R "${DSYM_PATH}" "${BUILT_PRODUCTS_DIR}/../../../dSYMs/"
    fi
done

echo "dSYM copy script completed"
