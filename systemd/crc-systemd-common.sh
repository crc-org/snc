# $1 is the resource to check
# $2 is an optional maximum retry count; default 20
function wait_for_resource() {
    local retry=0
    local max_retry=${2:-20}
    local wait_sec=${3:-5}
    until oc get "$1" > /dev/null 2>&1
    do
        [[ "$retry" -ge "$max_retry" ]] && exit 1
        sleep $wait_sec
        ((retry++))
    done

    return 0
}
