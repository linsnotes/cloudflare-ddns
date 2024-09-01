#!/bin/bash

# Exit Codes:
# 1: General error (e.g., failure to retrieve the current IP).
# 2: Error fetching the DNS record.
# 3: Error updating the DNS record.
# 4: Required tool (like jq) not installed.

# Cloudflare configuration:
# - Input your Cloudflare API token within the double quotes.
# - Input your Cloudflare Zone ID within the double quotes.
# - Input your Cloudflare Record ID within the double quotes.
# - Input the domain or subdomain you want to update (e.g., example.com or sub.example.com) within the double quotes.
CF_API_TOKEN=""
CF_ZONE_ID=""
CF_DOMAIN=""

# TTL value (in seconds), 1 is the default for automatic. If CF_PROXY=true, TTL is always automatic
CF_TTL=3600

# Proxy setting, true or false. If true, Cloudflare automatically manages the TTL
CF_PROXY=false

# Log file location
LOG_FILE="/var/log/update-cloudflare-ddns.log"

# Maximum number of retry attempts per service for fetching the current IP address
MAX_RETRIES=1

# Delay between retries (in seconds)
RETRY_DELAY=5

# Timeout for curl requests (in seconds)
CURL_TIMEOUT=10

# Cloudflare API base URL
CF_API_BASE_URL="https://api.cloudflare.com/client/v4"

# Global varibales that do not need to have values
CURRENT_IP=""
RECORD_IP=""
CF_RECORD_ID=""

# Function for logging
log() {
    echo "$(date) - $1"
}

# Function for checking if jq and curl are installed, install if missing
install_if_missing() {
    local cmd=$1
    local pkg=$2

    if ! command -v "$cmd" &> /dev/null; then
        log "INFO - $cmd not found, attempting to install..."

        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y "$pkg"
        elif command -v yum &> /dev/null; then
            yum install -y "$pkg"
        elif command -v dnf &> /dev/null; then
            dnf install -y "$pkg"
        elif command -v zypper &> /dev/null; then
            zypper install -y "$pkg"
        elif command -v pacman &> /dev/null; then
            pacman -Syu --noconfirm "$pkg"
        else
            log "ERROR - Package manager not supported. Please install $pkg manually."
            exit 4
        fi

        # Check if the installation was successful
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR - Failed to install $pkg."
            exit 4
        fi
    fi
}

# Function for getting the current external IP address
get_current_ip() {
    local current_ip retries
    for service in \
        "http://ipv4.icanhazip.com" \
        "https://domains.google.com/checkip" \
        "http://checkip.amazonaws.com"; do

        retries=0
        while [ $retries -lt $MAX_RETRIES ]; do
            current_ip=$(curl -s --max-time $CURL_TIMEOUT $service | sed -n 's/^\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\).*$/\1/p')
            if [[ -n $current_ip ]]; then
                echo "$current_ip"
                return 0
            else
                ((retries++))
                sleep $RETRY_DELAY
            fi
        done
    done
    log "ERROR - Unable to retrieve current IP address from all services"
    exit 1
}

# Function to fetch the current DNS record
get_dns_record() {
    local response
    response=$(curl -s --max-time $CURL_TIMEOUT -X GET "$CF_API_BASE_URL/zones/$CF_ZONE_ID/dns_records?type=A&name=$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the fetch was successful
    if echo "$response" | jq -e '.success' > /dev/null; then
        RECORD_IP=$(echo "$response" | jq -r '.result[0].content')
        CF_RECORD_ID=$(echo "$response" | jq -r '.result[0].id')
        log "INFO - Successfully fetched DNS record."
    else
        log "ERROR - Failed to fetch the DNS record. Response: $response"
        exit 2
    fi
}

# Function to update the Cloudflare DNS record
update_dns() {
    local json_payload
    json_payload=$(jq -n \
        --arg type "A" \
        --arg name "$CF_DOMAIN" \
        --arg content "$CURRENT_IP" \
        --argjson ttl "$CF_TTL" \
        --argjson proxied "$CF_PROXY" \
        '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')

    # log "INFO - JSON payload being sent: $json_payload"

    local update_result
    update_result=$(curl -s --max-time $CURL_TIMEOUT -X PUT "$CF_API_BASE_URL/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$json_payload")

    # Check if the update was successful
    if echo "$update_result" | jq -e '.success' > /dev/null; then
        log "SUCCESS - Updated DNS to $CURRENT_IP"
    else
        log "ERROR - Failed to update DNS. Response: $update_result"
        exit 3
    fi
}

# Main flow of the script

# Check if the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR - This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Redirect error to LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

log "START - ------ STARTING CLOUDFLARE DDNS UPDATE SCRIPT ------"

# Ensure required Cloudflare configuration variables are set
if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_DOMAIN" ]; then
    log "ERROR - Cloudflare API Token, Zone ID, Record ID and Domain must be set in the script."
    exit 1
fi

# Check if a command is installed, install if missing
install_if_missing jq jq
install_if_missing curl curl

# Get the current external IP address
CURRENT_IP=$(get_current_ip)

# Fetch the DNS record to get the current IP and Record ID
get_dns_record

# Default: Always update the DNS record, regardless of IP change.
# To enable Option 2 below, comment out Option 1.

# Option 1: Always update the DNS record, regardless of IP change.
log "INFO - Updating Cloudflare DNS record."
update_dns

# Option 2: Only update the DNS record if the IP address has changed.
# Uncomment the following block to enable this behavior and comment out Option 1 above:
# if [ "$CURRENT_IP" != "$RECORD_IP" ]; then
#     log "INFO - IP address has changed. Updating Cloudflare DNS record."
#     update_dns
# else
#     log "INFO - No change in IP address ($CURRENT_IP). No update necessary."
# fi
