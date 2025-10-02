#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

echo "➡️  Waiting for all APIServices to become available..."

MAX_RETRY=60
WAIT_SEC=5

for retry in $(seq 1 "$MAX_RETRY"); do
  # This command gets the 'status' of the 'Available' condition for every apiservice.
  # It produces a list of "True" and/or "False" strings. We then count how many are "False".
  UNAVAILABLE_COUNT=$(oc get apiservices -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' | grep "False" -c || true)

  if [ "$UNAVAILABLE_COUNT" -eq 0 ]; then
    echo "✅ All APIServices are now available."
    break
  fi

  echo
  echo "⏳ Still waiting for $UNAVAILABLE_COUNT APIService(s) to become available. Retrying in $WAIT_SEC seconds."
  echo "--------------------------------------------------------------------------------"
  echo "Unavailable services and their messages:"

  # Get all apiservices as JSON and pipe to jq for filtering and formatting.
  # The '-r' flag outputs raw strings instead of JSON-quoted strings.
  oc get apiservices -o json | jq -r '
      .items[] |
      . as $item |
      (
        $item.status.conditions[]? |
        select(.type == "Available" and .status == "False")
      ) |
      "  - \($item.metadata.name): \(.reason) - \(.message)"
    '

  echo "--------------------------------------------------------------------------------"

  # If it's the last attempt, log a failure message before exiting
  if [[ "$retry" -eq "$MAX_RETRY" ]]; then
      echo "Error: Timed out waiting for the api-services to get ready, after $MAX_RETRY attempts x $WAIT_SEC seconds." >&2
      exit 1
  fi

  sleep "$WAIT_SEC"
done

echo "🎉 Done."

exit 0
