#!/bin/bash

# Function to execute BigQuery commands with Rabbit API optimization
# Usage: rabbit-bq [command] [flags] [query]
# Currently supports: query
# Example: rabbit-bq query -q -n 0 --replace --destination_table my_table "SELECT * FROM table"
#
# Environment variables:
#   RABBIT_API_KEY - Rabbit API key (required)
#   RABBIT_API_URL - Rabbit API URL (optional, defaults to production)
#   BQ_OPTIMIZER_DEFAULT_PRICING_MODE - Default pricing mode: "on_demand" or "slot_based" (required)
#   BQ_OPTIMIZER_RESERVATION_IDS - Comma-separated list of reservation IDs (required)
#
# Command line flags:
#   --debug_mode - Show full API request/response for debugging
function rabbit-bq {
    # Check command argument
    if [[ $# -eq 0 ]]; then
        echo "Error: rabbit-bq requires a command (e.g., 'query')" >&2
        return 1
    fi
    
    local command="$1"
    shift  # Remove command from arguments
    
    # Route to appropriate command handler
    case "$command" in
        query)
            rabbit_bq_query "$@"
            ;;
        *)
            echo "Error: Unsupported command '$command'. Currently only 'query' is supported." >&2
            return 1
            ;;
    esac
}

# Internal function to handle query command with Rabbit API optimization
function rabbit_bq_query {
    # Parse --debug_mode flag
    local debug_mode=false
    local filtered_args=()
    
    for arg in "$@"; do
        if [[ "$arg" == "--debug_mode" ]]; then
            debug_mode=true
        else
            filtered_args+=("$arg")
        fi
    done
    
    # Store filtered arguments (without --debug_mode) for fallback
    local original_args=("${filtered_args[@]}")
    
    # Check required environment variables
    if [[ -z "$RABBIT_API_KEY" ]]; then
        echo "Error: RABBIT_API_KEY is required" >&2
        return 1
    fi
    
    if [[ -z "$BQ_OPTIMIZER_DEFAULT_PRICING_MODE" ]]; then
        echo "Error: BQ_OPTIMIZER_DEFAULT_PRICING_MODE is required" >&2
        return 1
    fi
    
    if [[ -z "$BQ_OPTIMIZER_RESERVATION_IDS" ]]; then
        echo "Error: BQ_OPTIMIZER_RESERVATION_IDS is required" >&2
        return 1
    fi
    
    # Validate default pricing mode
    if [[ "$BQ_OPTIMIZER_DEFAULT_PRICING_MODE" != "on_demand" ]] && [[ "$BQ_OPTIMIZER_DEFAULT_PRICING_MODE" != "slot_based" ]]; then
        echo "Error: BQ_OPTIMIZER_DEFAULT_PRICING_MODE must be 'on_demand' or 'slot_based'" >&2
        return 1
    fi
    
    # Use API URL from env or default
    local RABBIT_API_URL="${RABBIT_API_URL:-https://api.followrabbit.ai/bq-job-optimizer/v1/optimize-job}"
    
    # Build optimization config from env variables
    local default_pricing_mode="$BQ_OPTIMIZER_DEFAULT_PRICING_MODE"
    local reservation_ids="$BQ_OPTIMIZER_RESERVATION_IDS"
    
    # Convert comma-separated reservation IDs to JSON array
    local reservation_ids_array
    reservation_ids_array=$(echo "$reservation_ids" | jq -R -s -c 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    
    # Build the optimization config JSON
    local enabled_optimizations
    enabled_optimizations=$(jq -n \
        --arg pricing_mode "$default_pricing_mode" \
        --argjson reservation_ids "$reservation_ids_array" \
        '[{
            "type": "reservation_assignment",
            "config": {
                "defaultPricingMode": $pricing_mode,
                "reservationIds": $reservation_ids
            }
        }]')
    
    # Check if jq is available (required for JSON processing)
    if ! command -v jq > /dev/null 2>&1; then
        echo "jq not found, executing query without optimization" >&2
        bq query "${original_args[@]}"
        return $?
    fi
    
    # Extract query from filtered arguments (first non-flag argument onwards)
    local query=""
    local read_from_stdin=false
    local temp_query_file=""
    local query_start=0
    
    # Check if reading from stdin
    for arg in "${original_args[@]}"; do
        if [[ "$arg" == "-" ]]; then
            read_from_stdin=true
            break
        fi
    done
    
    # Read query from stdin if needed
    if [[ "$read_from_stdin" == true ]]; then
        temp_query_file=$(mktemp)
        cat > "$temp_query_file"
        query=$(cat "$temp_query_file")
    else
        # Find first non-flag argument (that's where the query starts)
        local i=0
        while [[ $i -lt ${#original_args[@]} ]]; do
            local arg="${original_args[$i]}"
            if [[ "$arg" != -* ]]; then
                query_start=$i
                break
            fi
            # Check if this flag takes a value and skip it
            case "$arg" in
                --destination_table|--format|--max_rows|--job_id|--job_id_file|--location|--project_id|--dataset_id|--table_id|--reservation_id)
                    i=$((i + 2))  # Skip flag and its value
                    continue
                    ;;
                -n)
                    i=$((i + 2))  # Skip flag and its value
                    continue
                    ;;
            esac
            # Regular flag (no value), just move to next
            i=$((i + 1))
        done
        
        # Extract query from remaining arguments
        if [[ $query_start -ge 0 ]] && [[ $query_start -lt ${#original_args[@]} ]]; then
            query=$(printf '%s ' "${original_args[@]:$query_start}")
            query="${query% }"  # Remove trailing space
        fi
    fi
    
    # If no query found, skip optimization and execute directly
    if [[ -z "$query" ]]; then
        echo "Could not extract query for optimization, executing without optimization" >&2
        bq query "${original_args[@]}"
        return $?
    fi
    
    # Build job configuration JSON - only send the query
    local query_escaped
    query_escaped=$(echo -n "$query" | jq -Rs .)
    
    # Build query config JSON with just the query
    local query_config
    query_config=$(jq -n --argjson query_str "$query_escaped" '{query: $query_str}')
    
    # Build request payload using jq
    # API expects: { job: { configuration: {...} }, enabledOptimizations: [...] }
    local request_payload
    request_payload=$(jq -n \
        --argjson query_config "$query_config" \
        --argjson optimizations "$enabled_optimizations" \
        '{job: {configuration: {query: $query_config}}, enabledOptimizations: $optimizations}')
    
    # Show API request if debug mode is enabled
    if [[ "$debug_mode" == true ]]; then
        echo "Rabbit API request:" >&2
        if echo "$request_payload" | jq . >/dev/null 2>&1; then
            echo "$request_payload" | jq . >&2
        else
            echo "$request_payload" >&2
        fi
        echo "" >&2
    fi
    
    # Call Rabbit API
    local temp_response=$(mktemp)
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$temp_response" \
        -X POST "$RABBIT_API_URL" \
        -H "Content-Type: application/json" \
        -H "rabbit-api-key: $RABBIT_API_KEY" \
        -d "$request_payload" \
        --max-time 10 \
        --connect-timeout 5 2>/dev/null)
    
    local optimized_config=""
    local use_reservation=false
    local reservation_id=""
    local optimization_performed=false
    local labels_json="{}"
    
    # Check if API call was successful
    if [[ "$http_code" == "200" ]]; then
        local response
        response=$(cat "$temp_response" 2>/dev/null)
        
        # Show API response in console only if debug mode is enabled
        if [[ "$debug_mode" == true ]]; then
            echo "Rabbit API response:" >&2
            if echo "$response" | jq . >/dev/null 2>&1; then
                echo "$response" | jq . >&2
            else
                echo "$response" >&2
            fi
            echo "" >&2
        fi
        
        rm -f "$temp_response"
        
        # Extract optimized configuration and check if optimization was performed
        optimized_config=$(echo "$response" | jq -r '.optimizedJob.configuration // empty' 2>/dev/null)
        optimization_performed=$(echo "$response" | jq -r '.optimizationResults[0].performed // false' 2>/dev/null)
        local optimization_comment=$(echo "$response" | jq -r '.optimizationResults[0].context.comment // ""' 2>/dev/null)
        local estimated_savings=$(echo "$response" | jq -r '.optimizationResults[0].estimatedSavings // 0' 2>/dev/null)
        
        # Check if reservation was assigned
        # Reservation is at the top level of configuration, not inside query
        local reservation_id_full=$(echo "$response" | jq -r '.optimizedJob.configuration.reservation // empty' 2>/dev/null)
        
        # Handle reservation assignment
        if [[ -n "$reservation_id_full" ]] && [[ "$reservation_id_full" != "null" ]] && [[ "$reservation_id_full" != "" ]]; then
            if [[ "$reservation_id_full" == "none" ]]; then
                # "none" means execute on-demand
                reservation_id="none"
                use_reservation=true  # Set flag to add --reservation_id=none to bq command
            else
                # Convert fully qualified format (projects/.../locations/.../reservations/...) to short format (project:region.name)
                # Format: projects/PROJECT_ID/locations/LOCATION/reservations/RESERVATION_NAME
                if [[ "$reservation_id_full" =~ ^projects/([^/]+)/locations/([^/]+)/reservations/(.+)$ ]]; then
                    local project_id="${BASH_REMATCH[1]}"
                    local location="${BASH_REMATCH[2]}"
                    local reservation_name="${BASH_REMATCH[3]}"
                    reservation_id="${project_id}:${location}.${reservation_name}"
                    use_reservation=true
                else
                    # If it's already in short format, use it as-is
                    reservation_id="$reservation_id_full"
                    use_reservation=true
                fi
            fi
        else
            reservation_id=""
        fi
        
        # Extract labels from optimized configuration
        labels_json=$(echo "$response" | jq -r '.optimizedJob.configuration.labels // {}' 2>/dev/null)
        
        # Log optimization decision
        echo "" >&2
        echo "=== Rabbit API Optimization Result ===" >&2
        if [[ "$optimization_performed" == "true" ]]; then
            echo "✓ Optimization applied" >&2
            if [[ "$reservation_id" == "none" ]]; then
                echo "  → Using on-demand pricing (reservation_id=none)" >&2
            elif [[ -n "$reservation_id" ]] && [[ "$reservation_id" != "null" ]] && [[ "$reservation_id" != "" ]]; then
                echo "  → Using reservation: $reservation_id" >&2
            fi
            if [[ -n "$estimated_savings" ]] && [[ "$estimated_savings" != "0" ]] && [[ "$estimated_savings" != "null" ]]; then
                echo "  → Estimated savings: \$$(printf "%.4f" "$estimated_savings")" >&2
            fi
            if [[ -n "$optimization_comment" ]] && [[ "$optimization_comment" != "null" ]]; then
                echo "  → Reason: $optimization_comment" >&2
            fi
        else
            echo "○ No optimization recommended" >&2
            if [[ -n "$optimization_comment" ]] && [[ "$optimization_comment" != "null" ]] && [[ "$optimization_comment" != "" ]]; then
                echo "  → Reason: $optimization_comment" >&2
            else
                echo "  → Using original configuration" >&2
            fi
        fi
        echo "=====================================" >&2
        echo "" >&2
    else
        local error_response
        error_response=$(cat "$temp_response" 2>/dev/null)
        echo "Rabbit API call failed (HTTP ${http_code:-unknown}), using original configuration" >&2
        if [[ -n "$error_response" ]]; then
            echo "Rabbit API error response:" >&2
            # Try to pretty-print JSON error, fallback to raw output
            if echo "$error_response" | jq . >/dev/null 2>&1; then
                echo "$error_response" | jq . >&2
            else
                echo "$error_response" >&2
            fi
        fi
        rm -f "$temp_response"
    fi
    
    # Execute the query with optimized arguments if reservation was recommended
    local exit_code=0
    local bq_cmd_args=()
    local query_args=()
    local i=0
    local in_query=false
    
    # Separate flags from query arguments, handling flags that take values
    while [[ $i -lt ${#original_args[@]} ]]; do
        local arg="${original_args[$i]}"
        
        if [[ "$arg" == -* ]]; then
            # It's a flag, add it to bq_cmd_args
            bq_cmd_args+=("$arg")
            
            # Check if this flag takes a value
            case "$arg" in
                --destination_table|--format|--max_rows|--job_id|--job_id_file|--location|--project_id|--dataset_id|--table_id|--reservation_id)
                    # This flag takes a value, include the next argument
                    i=$((i + 1))
                    if [[ $i -lt ${#original_args[@]} ]]; then
                        bq_cmd_args+=("${original_args[$i]}")
                    fi
                    ;;
                -n)
                    # -n takes a value, include the next argument
                    i=$((i + 1))
                    if [[ $i -lt ${#original_args[@]} ]]; then
                        bq_cmd_args+=("${original_args[$i]}")
                    fi
                    ;;
            esac
        else
            # First non-flag argument starts the query
            if [[ $in_query == false ]]; then
                in_query=true
            fi
            # All non-flag arguments are part of the query
            query_args+=("$arg")
        fi
        
        i=$((i + 1))
    done
    
    # If reservation was recommended (including "none" for on-demand), add --reservation_id flag (before query)
    if [[ "$use_reservation" == true ]] && [[ -n "$reservation_id" ]]; then
        # Check if --reservation_id is already in the arguments (user-specified)
        local has_reservation_flag=false
        for arg in "${bq_cmd_args[@]}"; do
            if [[ "$arg" == --reservation_id=* ]] || [[ "$arg" == --reservation_id ]]; then
                has_reservation_flag=true
                break
            fi
        done
        
        # Only add reservation flag if not already present
        if [[ "$has_reservation_flag" == false ]]; then
            bq_cmd_args+=("--reservation_id=$reservation_id")
        fi
    fi
    
    # Add labels from optimized configuration (before query)
    if [[ -n "$labels_json" ]] && [[ "$labels_json" != "{}" ]] && [[ "$labels_json" != "null" ]]; then
        # Extract each label and add as --label=KEY:VALUE
        local label_keys
        label_keys=$(echo "$labels_json" | jq -r 'keys[]' 2>/dev/null)
        
        if [[ -n "$label_keys" ]]; then
            while IFS= read -r label_key; do
                local label_value
                label_value=$(echo "$labels_json" | jq -r ".[\"$label_key\"]" 2>/dev/null)
                
                if [[ -n "$label_value" ]] && [[ "$label_value" != "null" ]]; then
                    # Check if this label is already in the arguments
                    local label_exists=false
                    for arg in "${bq_cmd_args[@]}"; do
                        if [[ "$arg" == --label=* ]] && [[ "$arg" == *"$label_key:"* ]]; then
                            label_exists=true
                            break
                        fi
                    done
                    
                    # Only add label if not already present
                    if [[ "$label_exists" == false ]]; then
                        bq_cmd_args+=("--label=$label_key:$label_value")
                    fi
                fi
            done <<< "$label_keys"
        fi
    fi
    
    # Show final bq command in debug mode
    if [[ "$debug_mode" == true ]]; then
        echo "Executing bq query command:" >&2
        echo "  bq query ${bq_cmd_args[*]} ${query_args[*]}" >&2
        echo "" >&2
    fi
    
    # Execute the query with flags first, then query arguments
    bq query "${bq_cmd_args[@]}" "${query_args[@]}" || exit_code=$?
    
    # If execution failed and we added a reservation, try without it (fallback to original)
    if [[ $exit_code -ne 0 ]] && [[ "$use_reservation" == true ]] && [[ -n "$reservation_id" ]]; then
        echo "Query with reservation failed, retrying with original configuration..." >&2
        if [[ "$debug_mode" == true ]]; then
            echo "Executing fallback bq query command:" >&2
            echo "  bq query ${original_args[*]}" >&2
            echo "" >&2
        fi
        bq query "${original_args[@]}" || exit_code=$?
    fi
    
    # Cleanup
    [[ -n "$temp_query_file" ]] && rm -f "$temp_query_file"
    
    return $exit_code
}

