# Olympus Mytikas

Olympus Mytikas brings the guild's recruitment tools and Kill on Sight board into one World of Warcraft addon. Open its window from the minimap to post a recruitment message, review enemy sightings and bounties, or see the installed version.

## Publish a release

Once the CurseForge project is connected, publishing a stable GitHub release starts the upload. GitHub Actions builds the installable ZIP, attaches it to the release, and submits the same bytes to CurseForge. Member Home can continue importing the GitHub asset.

1. Update `## Version` in `OlympusMytikas/OlympusMytikas.toc` and add the changes to `OlympusMytikas/CHANGELOG.txt`. If moving to a new Forever client version, update both the TOC and the supported Forever version in `scripts/publish_curseforge.py`. Merge the changes to `main` after **Addon behavior** passes.
2. In GitHub Releases, select **Draft a new release**. Choose a new tag matching the manifest with a leading `v` (for example, `v1.0.2` for `1.0.2`), and target the reviewed commit on `main`. Enter the player-facing changes in the release notes. This text becomes the public CurseForge changelog. Leave the prerelease box unchecked. [Draft a GitHub release](https://github.com/Mytikas-Monster/OlympusMytikas/releases/new)
3. Click **Publish release**. Open **Actions → Publish to CurseForge** for the result. The release assets should include `OlympusMytikas-X.Y.Z.zip` and, once CurseForge accepts the upload, `curseforge-receipt.json` containing its file ID. [Workflow runs](https://github.com/Mytikas-Monster/OlympusMytikas/actions/workflows/publish-curseforge.yml)
4. Open the file in the CurseForge author dashboard to see its moderation status. Once approved, check that the public Files page offers the tagged version for **WoW Forever**. A player can install it from the CurseForge app for their Forever installation. For a direct check, download the public file and compare its SHA-256 with the GitHub release asset digest. [CurseForge file submission and review](https://support.curseforge.com/support/solutions/articles/9000197241-creating-and-submitting-a-project)

## Connect CurseForge for the first time

1. Sign in to the CurseForge author account that manages **Olympus Mytikas**. Open its project, or create a **World of Warcraft → Addons** project with **Guild** as its primary category. Use the guild's logo and owner-approved license and distribution settings. Copy the numeric project ID from the project overview. [Author dashboard](https://authors.curseforge.com/) · [Create a project](https://authors.curseforge.com/#/projects/create/choose-game)
2. Generate an author upload token for an account with file-upload permission on the project. In the GitHub repository, go to **Settings → Secrets and variables → Actions**. Under **Variables**, create `CURSEFORGE_PROJECT_ID` with the numeric project ID. Under **Secrets**, create `CURSEFORGE_API_TOKEN` with the token. The workflow uses GitHub's automatic token to attach the ZIP and record the upload. Keep release assets writable for those steps. [CurseForge Upload API and token settings](https://support.curseforge.com/support/solutions/articles/9000197321) · [GitHub Actions settings](https://github.com/Mytikas-Monster/OlympusMytikas/settings/secrets/actions)
3. For the first file on a new listing, open **Actions → Publish to CurseForge → Run workflow**. Select `main` and enter the existing release tag `v1.0.1`. This submits the original GitHub ZIP with SHA-256 `bfdcf506002e4d63da4b2bffb7d8b9603e07a7f8ab95d33dd83b9b7f7b23893b`. Check the dashboard for a single **Release** file for **WoW Forever 1.60.1**, set for automatic release after moderation. [Release v1.0.1](https://github.com/Mytikas-Monster/OlympusMytikas/releases/tag/v1.0.1)

**Suggested listing copy**

| Field | Text |
| --- | --- |
| Name | Olympus Mytikas |
| Summary | Guild recruitment messages, enemy sightings, bounties and map pins for Olympus Mytikas in WoW Forever. |
| Description | Click the minimap button to open the guild window. The Recruit tab lets you choose or write a recruitment ad and post it to General and Trade. The Kill on Sight tab shares reports of enemy players and their last-known locations with guildmates, tracks bounties, and shows the monthly hunter board. The addon includes its map libraries. |

## Recover a release

To retry submission of an existing release ZIP, use **Run workflow** on `main` and enter the original tag. If a new GitHub release failed before its ZIP was attached, open its original release-triggered run and choose **Re-run failed jobs** to retry packaging. A matching receipt makes subsequent runs safe. Keep the same ZIP for each version. Ship changed addon bytes under a new version and tag.

| Result | Maintainer action |
| --- | --- |
| Setup or compatibility check failed before submission | Read the failed step, fix the named setting or version mapping, then run the workflow for the same tag. |
| CurseForge returned a file ID | Check that file's status in the author dashboard. If moderation requests changes, follow the feedback there. |
| Only `curseforge-pending.json` exists | Wait for any active run for the tag to finish. Check **Files** in the author dashboard, including files under review. A network timeout can occur after CurseForge received the file. |

If the dashboard contains the file after an interrupted upload, verify its filename, project and SHA-256 against the GitHub archive. Record the confirmed file ID to complete the receipt without another upload. Run the commands below with GitHub CLI and `jq`, substituting the affected tag and actual numeric file ID.

```sh
repo=Mytikas-Monster/OlympusMytikas
tag=v1.0.2
file_id=1234567
receipt_dir=$(mktemp -d)
gh release download "$tag" -R "$repo" -p curseforge-pending.json -D "$receipt_dir"
jq --argjson id "$file_id" '. + {fileId: $id}' \
  "$receipt_dir/curseforge-pending.json" > "$receipt_dir/curseforge-receipt.json"
gh release upload "$tag" "$receipt_dir/curseforge-receipt.json" -R "$repo"
```

If the author confirms that no upload occurred, clear the pending marker for that tag with `gh release delete-asset "$tag" curseforge-pending.json -R "$repo" --yes`. Dispatch the workflow again. Keep the marker while the outcome is uncertain.

## Local checks

Run the Lua checks from the repository root with Lua 5.1. To test packaging without publishing, use a local release tag whose manifest has the matching version. The package commands use the tree stored in that tag.

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
luac5.1 -p OlympusMytikas/*.lua OlympusMytikas/libs/*.lua
lua5.1 tests/shared-window.lua
lua5.1 tests/gameplay.lua
tag=v1.0.2
archive_dir=$(mktemp -d)
archive="$archive_dir/OlympusMytikas-${tag#v}.zip"
python3 scripts/package_addon.py build "$tag" "$archive"
python3 scripts/package_addon.py validate "$tag" "$archive"
```
