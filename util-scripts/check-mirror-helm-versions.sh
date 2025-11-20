#!/bin/bash
# Check versions of all Helm binaries published on OpenShift mirror
# Usage: ./check-mirror-helm-versions.sh [-d|--directory CACHE_DIR]

set -e

BASE_URL="https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/helm"
#BINARY="helm-darwin-arm64"
BINARY="helm-darwin-amd64"
TEMP_DIR=$(mktemp -d)
CACHE_DIR=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--directory)
            CACHE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-d|--directory CACHE_DIR]"
            echo "  -d, --directory  Cache directory to save/download Helm binaries"
            echo "                  Binary names: ${BINARY}-VERSION"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Create cache directory if specified
if [ -n "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
fi

VERSIONS=("3.1.1" "3.1.3" "3.2.3" "3.3.4" "3.5.0" "3.6.2" "3.7.1" "3.9.0" "3.10.1" "3.11.1" "3.12.1" "3.12.1-20" "3.13.2" "3.14.4" "3.15.4" "3.17.0" "3.17.1" "latest")

trap "rm -rf $TEMP_DIR" EXIT

for VERSION in "${VERSIONS[@]}"; do
    BINARY_PATH="$TEMP_DIR/helm-$VERSION"
    CACHE_BINARY_PATH=""
    DOWNLOAD_URL="$BASE_URL/$VERSION/$BINARY"
    
    # Check cache first if cache directory is specified
    if [ -n "$CACHE_DIR" ]; then
        CACHE_BINARY_PATH="$CACHE_DIR/${BINARY}-${VERSION}"
        if [ -f "$CACHE_BINARY_PATH" ] && [ -s "$CACHE_BINARY_PATH" ]; then
            echo "[Using cached $VERSION...]"
            cp "$CACHE_BINARY_PATH" "$BINARY_PATH"
        fi
    fi
    
    # Download if not in cache or cache not enabled
    if [ ! -f "$BINARY_PATH" ] || [ ! -s "$BINARY_PATH" ]; then
        echo "[Downloading $VERSION...]"
        HTTP_CODE=$(curl -sSL -o "$BINARY_PATH" -w "%{http_code}" "$DOWNLOAD_URL" 2>/dev/null)
        if [ "$HTTP_CODE" != "200" ]; then
            if [ "$HTTP_CODE" = "404" ]; then
                echo "$VERSION: [Binary not available - HTTP 404]"
            elif [ "$HTTP_CODE" = "000" ]; then
                echo "$VERSION: [Download failed - connection error]"
            else
                echo "$VERSION: [Download failed - HTTP $HTTP_CODE]"
            fi
            echo ""
            rm -f "$BINARY_PATH"
            continue
        fi
        
        # Save to cache if cache directory is specified
        if [ -n "$CACHE_DIR" ] && [ -f "$BINARY_PATH" ] && [ -s "$BINARY_PATH" ]; then
            cp "$BINARY_PATH" "$CACHE_BINARY_PATH"
            chmod +x "$CACHE_BINARY_PATH"
            xattr -d com.apple.quarantine "$CACHE_BINARY_PATH" 2>/dev/null || true
        fi
    fi

    if [ -f "$BINARY_PATH" ] && [ -s "$BINARY_PATH" ]; then
        # Remove macOS quarantine attribute
        xattr -d com.apple.quarantine "$BINARY_PATH" 2>/dev/null || true

        chmod +x "$BINARY_PATH"
        VERSION_OUTPUT=$("$BINARY_PATH" version 2>&1)
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ] && [ -n "$VERSION_OUTPUT" ]; then
            echo "$VERSION:"
            echo "$VERSION_OUTPUT"
            echo ""
        else
            echo "$VERSION: [Failed to execute - exit code: $EXIT_CODE]"
            [ -n "$VERSION_OUTPUT" ] && echo "Error: $VERSION_OUTPUT"
            echo ""
        fi
    else
        echo "$VERSION: [Download failed or empty]"
        echo ""
    fi
done

echo ""
echo " Summary"
echo "=============="
echo ""
printf "%-12s %-15s %-20s %-15s\n" "Mirror Ver" "Helm Version" "Go Version" "Git Commit"
printf "%-12s %-15s %-20s %-15s\n" "----------" "------------" "----------" "----------"

for VERSION in "${VERSIONS[@]}"; do
    BINARY_PATH="$TEMP_DIR/helm-$VERSION"
    DOWNLOAD_URL="$BASE_URL/$VERSION/$BINARY"
    
    # Check cache if binary not in temp dir
    if [ ! -f "$BINARY_PATH" ] || [ ! -s "$BINARY_PATH" ]; then
        if [ -n "$CACHE_DIR" ]; then
            CACHE_BINARY_PATH="$CACHE_DIR/${BINARY}-${VERSION}"
            if [ -f "$CACHE_BINARY_PATH" ] && [ -s "$CACHE_BINARY_PATH" ]; then
                cp "$CACHE_BINARY_PATH" "$BINARY_PATH"
            fi
        fi
    fi

    if [ -f "$BINARY_PATH" ] && [ -s "$BINARY_PATH" ]; then
        # Ensure quarantine removed again
        xattr -d com.apple.quarantine "$BINARY_PATH" 2>/dev/null || true
        chmod +x "$BINARY_PATH"

        VERSION_OUTPUT=$("$BINARY_PATH" version 2>/dev/null)
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ] && [ -n "$VERSION_OUTPUT" ]; then
            HELM_VER=$(echo "$VERSION_OUTPUT" | grep -o 'Version:"v[^"]*"' | sed 's/Version:"//;s/"//')
            GO_VER=$(echo "$VERSION_OUTPUT" | grep -o 'GoVersion:"[^"]*"' | sed 's/GoVersion:"//;s/"//' | cut -d' ' -f1)
            GIT_COMMIT=$(echo "$VERSION_OUTPUT" | grep -o 'GitCommit:"[^"]*"' | sed 's/GitCommit:"//;s/"//' | cut -c1-10)

            [ -z "$HELM_VER" ] && HELM_VER="unknown"
            [ -z "$GO_VER" ] && GO_VER="unknown"
            [ -z "$GIT_COMMIT" ] && GIT_COMMIT="unknown"

            printf "%-12s %-15s %-20s %-15s\n" "$VERSION" "$HELM_VER" "$GO_VER" "$GIT_COMMIT"
        else
            printf "%-12s %-15s %-20s %-15s\n" "$VERSION" "EXEC FAILED" "N/A" "N/A"
        fi
    else
        # Check HTTP status to provide more specific error message
        HTTP_CODE=$(curl -sSL -o /dev/null -w "%{http_code}" "$DOWNLOAD_URL" 2>/dev/null)
        if [ "$HTTP_CODE" = "404" ]; then
            printf "%-12s %-15s %-20s %-15s\n" "$VERSION" "NOT AVAILABLE" "N/A" "N/A"
        else
            printf "%-12s %-15s %-20s %-15s\n" "$VERSION" "NOT FOUND" "N/A" "N/A"
        fi
    fi
done

echo ""