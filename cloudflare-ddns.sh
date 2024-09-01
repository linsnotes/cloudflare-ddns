#!/bin/bash

# Cloudflare configuration:
# - Input your Cloudflare API token within the double quotes.
# - Input your Cloudflare Zone ID within the double quotes.
# - Input your Cloudflare Record ID within the double quotes.
# - Input the domain or subdomain you want to update (e.g., example.com or sub.example.com) within the double quotes.
CF_API_TOKEN=""
CF_ZONE_ID=""
CF_DOMAIN=""

# CF_TTL and CF_PROXY settings:
# For DDNS, it is recommended to keep TTL at a low value (e.g., 60 seconds) to ensure quick IP updates.
# CF_PROXY should be set to false, as enabling the proxy is not suitable for DDNS. 
# Changing these settings is not advised unless the implications are fully understood.
CF_TTL=60
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

# Function for checking if required commands are installed and installing them if missing
ensure_dependencies_installed() {
    # Declare an associative array to map commands to their package names
    declare -A cmd_pkg_map=( ["jq"]="jq" ["curl"]="curl" )

    # Loop through the array to check each command
    for cmd in "${!cmd_pkg_map[@]}"; do
        # Check if the command is not found on the system
        if ! command -v "$cmd" &> /dev/null; then
            log "INFO - $cmd not found, attempting to install..."

            # Get the package name associated with the command
            pkg=${cmd_pkg_map[$cmd]}

            # Detect the package manager and install the package
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
                # If no known package manager is found, log an error and exit
                log "ERROR - Package manager not supported. Please install $pkg manually."
                exit 1
            fi

            # After installation, verify that the command is now available
            if ! command -v "$cmd" &> /dev/null; then
                log "ERROR - Failed to install $pkg."
                exit 1
            fi
        fi
    done
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
        exit 1
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

    # Perform the update and capture both the response body and HTTP status code
    local update_result
    local http_status

    update_result=$(curl -s -w "\n%{http_code}" --max-time $CURL_TIMEOUT -X PUT "$CF_API_BASE_URL/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$json_payload")

    # Extract the HTTP status code (last line) and the response body (all but last line)
    http_status=$(echo "$update_result" | tail -n1)
    update_result=$(echo "$update_result" | sed '$d')

    # Check if the update was successful based on the HTTP status code
    if [ "$http_status" -eq 200 ]; then
        if echo "$update_result" | jq -e '.success' > /dev/null; then
            log "SUCCESS - Updated DNS to $CURRENT_IP"
        else
            local error_message
            error_message=$(echo "$update_result" | jq -r '.errors[0].message')
            log "ERROR - Failed to update DNS. Cloudflare error: $error_message. Response: $update_result"
            exit 1
        fi
    else
        log "ERROR - Failed to update DNS. HTTP Status: $http_status. Response: $update_result"
        case "$http_status" in
            400)
                log "ERROR - Bad Request. Check the JSON payload and ensure all required fields are correct."
                ;;
            401)
                log "ERROR - Unauthorized. Verify that the API token is correct and has the necessary permissions."
                ;;
            403)
                log "ERROR - Forbidden. Ensure that the API token has sufficient permissions for the requested operation."
                ;;
            404)
                log "ERROR - Not Found. Verify that the Zone ID and Record ID are correct."
                ;;
            429)
                log "ERROR - Rate limit exceeded. Consider adding a delay between requests or contact Cloudflare support."
                ;;
            500|502|503|504)
                log "ERROR - Server error. Cloudflare might be experiencing issues. Try again later."
                ;;
            *)
                log "ERROR - An unexpected error occurred. HTTP Status: $http_status."
                ;;
        esac
        exit 1
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
ensure_dependencies_installed

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
