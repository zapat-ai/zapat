# Add Repository

Add a new repository to Zapat's monitoring list.

## Steps

1. Ask the user for:
   - **GitHub path**: `owner/repo` (e.g., `acme-corp/new-service`)
   - **Local path**: where the repo is cloned locally (e.g., `/home/you/code/new-service`)
   - **Type**: `backend`, `web`, `ios`, `mobile`, `extension`, `marketing`, or `other`

2. Validate the local path exists:
   ```bash
   ls -d <local_path>
   ```
   If it does not exist, ask if they want to clone it:
   ```bash
   gh repo clone <owner/repo> <local_path>
   ```

3. Check that the repo is not already in `config/repos.conf`. If it is, inform the user and ask if they want to update the existing entry.

4. Append the new entry to `config/repos.conf`:
   ```
   owner/repo	/path/to/local/clone	type
   ```

5. Ask: "Set up pipeline labels on this repo? (recommended for first-time repos)"
   If yes, run:
   ```bash
   bin/setup-labels.sh
   ```
   This creates the required labels (`agent`, `agent-work`, `agent-research`, `hold`, `human-only`, and internal status labels) on the repo.

6. Confirm:
   ```
   Added acme-corp/new-service to Zapat.
   The pipeline will pick it up on the next poll cycle (within 2 minutes).
   ```
