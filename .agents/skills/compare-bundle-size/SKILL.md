# compare-bundle-size

Compare the last-layer image sizes between two OpenShift release bundles.

## When to use

Trigger this skill when the user types `/compare-bundle-size` or asks to compare OpenShift bundle sizes, release sizes, or image layer growth between two versions.

## Instructions

1. Ask the user which two bundle versions they want to compare using `AskUserQuestion`. Provide common recent versions as options and allow free-text input via "Other".

2. Once both versions are provided, run the comparison script:
   ```
   bash compare_bundle_size.sh <BUNDLE1> <BUNDLE2>
   ```
   The script lives at the project root: `.agents/skills/compare-bundle-size/compare_bundle_size.sh`

3. Present the results to the user in a clear summary:
   - Total size difference (printed to stderr by the script)
   - Top images that grew the most (by absolute MB)
   - Top images that shrank the most (by absolute MB)
   - Any images with >50% growth as notable outliers

4. If the script fails (e.g. missing `oc`, invalid version, network error), report the error clearly and suggest the user check:
   - That `oc` CLI is installed and authenticated
   - That `~/pull-secret` exists
   - That the bundle version string is valid (e.g. `4.21.18`, `4.22.0-rc.5`)
