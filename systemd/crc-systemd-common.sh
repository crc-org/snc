# $1 is the resource to check
# $2 is an optional maximum retry count; default 20
function wait_for_resource_or_die() {
    local resource=${1:-}
    local max_retry=${2:-20}
    local wait_sec=${3:-5}

    local xtrace_was_disabled=0
    # Check if xtrace is currently DISABLED. If so, set a flag.
    [[ $- == *x* ]] || xtrace_was_disabled=1
    set +x # disable xtrace to reduce the verbosity of this function

    if [[ -z "$resource" ]]; then
        echo "ERROR: expected a K8s resource as first parameter ..."
        echo "ERROR: wait_for_resource_or_die RESOURCE [max_retry=20] [wait_sec=5]"
        exit 1 # this is wait_for_resource_or_die, so die ...
    fi

    # Loop from 1 up to max_retry
    for (( retry=1; retry<=max_retry; retry++ )); do
        # Try the command. If it succeeds, exit the loop.
        if oc get $resource > /dev/null 2>&1; then
            local end_time
            end_time=$(date +%s)

            local duration=$((end_time - start_time))
            echo "Resource '$resource' found after $retry tries ($duration seconds)."

            if (( ! xtrace_was_disabled )); then
                set -x # reenable xtrace
            fi

            return 0
        fi

        # If it's the last attempt, log a failure message before exiting
        if (( retry == max_retry )); then
            echo "Error: Timed out waiting for resource '$resource' after ${max_retry} attempts x ${wait_sec} seconds." >&2
            exit 1 # this is wait_for_resource_or_die, so die ...
        fi

        # Wait before the next attempt
        echo "Attempt ${retry}/${max_retry} didn't succeed."
        echo "Waiting $wait_sec seconds for '$resource'."
        sleep "$wait_sec"
    done

    # unreachable
}
