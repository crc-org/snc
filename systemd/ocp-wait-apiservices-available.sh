#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

echo "➡️  Waiting for all APIServices to become available..."

SECONDS=0
MAX_RETRY=60
WAIT_SEC=5

for retry in $(seq 1 "$MAX_RETRY"); do
    # This command gets the 'status' of the 'Available' condition for every apiservice.
    # It produces a list of "True" and/or "False" strings. We then count how many are "False".
    APISERVICE_DATA=$(oc get apiservices -o json 2>/dev/null || true)
    if [[ -z "$APISERVICE_DATA" ]]; then
        UNAVAILABLE_COUNT=999
        echo "⚠️ Couldn't get the list of apiservices ..."
    else
        UNAVAILABLE_COUNT=$(jq -r '
          [ .items[]
            | select(((.status.conditions // [])
                      | any(.type=="Available" and .status=="True")) | not)
          ] | length
        ' <<<"$APISERVICE_DATA")
        UNAVAILABLE_COUNT=${UNAVAILABLE_COUNT:-0}
    fi

    if [ "$UNAVAILABLE_COUNT" -eq 0 ]; then
        echo "✅ All APIServices are now available after $SECONDS seconds."
        break
    fi

    echo
    echo "⏳ Still waiting for $UNAVAILABLE_COUNT APIService(s) to become available. Retrying in $WAIT_SEC seconds."
    echo "--------------------------------------------------------------------------------"
    echo "Unavailable services and their messages:"

    # Get all apiservices as JSON and pipe to jq for filtering and formatting.
    # The '-r' flag outputs raw strings instead of JSON-quoted strings.
    if ! oc get apiservices -o json | jq -r '
      .items[] |
      . as $item |
      (
        $item.status.conditions[]? |
        select(.type == "Available" and .status == "False")
      ) |
      "  - \($item.metadata.name): \(.reason) - \(.message)"
    '
    then
        echo "⚠️  Unable to list unavailable APIServices details (will retry)" >&2
    fi

    echo "--------------------------------------------------------------------------------"

    # If it's the last attempt, log a failure message before exiting
    if (( retry == MAX_RETRY )); then
        echo "ERROR: Timed out waiting for the api-services to get ready, after $MAX_RETRY attempts x $WAIT_SEC seconds = $SECONDS seconds." >&2
        exit 1
    fi

    sleep "$WAIT_SEC"
done

echo "🎉 Done."

exit 0
