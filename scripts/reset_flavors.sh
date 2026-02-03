#!/bin/bash

# Reset script for Comunifi app flavors (admin and member)
# This script completely resets app data including KeyChain private keys

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Bundle identifiers for each flavor
ADMIN_BUNDLE_ID="io.comunifi.app.admin"
MEMBER_BUNDLE_ID="io.comunifi.app.member"
BASE_BUNDLE_ID="io.comunifi.app"

# Keychain account name (from secure_storage.dart)
KEYCHAIN_ACCOUNT="comunifi"

echo -e "${YELLOW}=== Comunifi App Reset Script ===${NC}"
echo ""

# Function to delete keychain entries for a bundle ID
delete_keychain_entries() {
    local bundle_id=$1
    echo -e "${YELLOW}Deleting Keychain entries for ${bundle_id}...${NC}"

    # Delete all keychain entries with matching service (bundle ID)
    # The -a flag specifies the account name
    # We loop to delete all matching entries
    while security delete-generic-password -s "$bundle_id" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null; do
        echo "  Deleted keychain entry with service: $bundle_id"
    done

    # Also try without account name to catch any other entries
    while security delete-generic-password -s "$bundle_id" 2>/dev/null; do
        echo "  Deleted keychain entry with service: $bundle_id (no account)"
    done

    echo -e "${GREEN}  Keychain entries cleaned for ${bundle_id}${NC}"
}

# Function to delete app data directories
delete_app_data() {
    local bundle_id=$1
    echo -e "${YELLOW}Deleting app data for ${bundle_id}...${NC}"

    # Application Support
    local app_support="$HOME/Library/Application Support/$bundle_id"
    if [ -d "$app_support" ]; then
        rm -rf "$app_support"
        echo "  Deleted: $app_support"
    else
        echo "  Not found: $app_support"
    fi

    # Caches
    local caches="$HOME/Library/Caches/$bundle_id"
    if [ -d "$caches" ]; then
        rm -rf "$caches"
        echo "  Deleted: $caches"
    else
        echo "  Not found: $caches"
    fi

    # Preferences
    local prefs="$HOME/Library/Preferences/${bundle_id}.plist"
    if [ -f "$prefs" ]; then
        rm -f "$prefs"
        echo "  Deleted: $prefs"
    else
        echo "  Not found: $prefs"
    fi

    # Containers (for sandboxed apps)
    # Note: macOS protects container metadata, so we delete contents but not the container itself
    local containers="$HOME/Library/Containers/$bundle_id"
    if [ -d "$containers" ]; then
        # Delete Data directory contents (app data)
        if [ -d "$containers/Data" ]; then
            rm -rf "$containers/Data"/* 2>/dev/null || true
            rm -rf "$containers/Data"/.[!.]* 2>/dev/null || true
            echo "  Cleared contents: $containers/Data"
        fi
        # Try to delete the container (may fail due to SIP)
        rm -rf "$containers" 2>/dev/null || echo "  Note: Container metadata protected by macOS (this is normal)"
    else
        echo "  Not found: $containers"
    fi

    # Saved Application State
    local saved_state="$HOME/Library/Saved Application State/${bundle_id}.savedState"
    if [ -d "$saved_state" ]; then
        rm -rf "$saved_state"
        echo "  Deleted: $saved_state"
    else
        echo "  Not found: $saved_state"
    fi

    # HTTPStorages
    local http_storage="$HOME/Library/HTTPStorages/$bundle_id"
    if [ -d "$http_storage" ]; then
        rm -rf "$http_storage"
        echo "  Deleted: $http_storage"
    else
        echo "  Not found: $http_storage"
    fi

    echo -e "${GREEN}  App data cleaned for ${bundle_id}${NC}"
}

# Kill any running instances
echo -e "${YELLOW}Killing any running app instances...${NC}"
pkill -f "comunifi" 2>/dev/null || true
echo -e "${GREEN}  Done${NC}"
echo ""

# Reset Admin flavor
echo -e "${YELLOW}=== Resetting ADMIN flavor ===${NC}"
delete_keychain_entries "$ADMIN_BUNDLE_ID"
delete_app_data "$ADMIN_BUNDLE_ID"
echo ""

# Reset Member flavor
echo -e "${YELLOW}=== Resetting MEMBER flavor ===${NC}"
delete_keychain_entries "$MEMBER_BUNDLE_ID"
delete_app_data "$MEMBER_BUNDLE_ID"
echo ""

# Also reset base bundle ID (in case default flavor was run)
echo -e "${YELLOW}=== Resetting BASE flavor (default) ===${NC}"
delete_keychain_entries "$BASE_BUNDLE_ID"
delete_app_data "$BASE_BUNDLE_ID"
echo ""

# Clear Flutter build cache (optional but recommended)
echo -e "${YELLOW}Clearing Flutter build cache...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -d "$PROJECT_DIR/build" ]; then
    rm -rf "$PROJECT_DIR/build"
    echo "  Deleted: $PROJECT_DIR/build"
fi
echo -e "${GREEN}  Done${NC}"
echo ""

echo -e "${GREEN}=== Reset Complete ===${NC}"
echo ""
echo "You can now run the apps fresh with:"
echo "  flutter run --flavor admin"
echo "  flutter run --flavor member"
